//
//  FlashcardSessionViewModel.swift
//  EnglishHelper — Presentation
//
//  Today's practice, card by card — show the prompt, reveal the answer, rate it (Again / Hard / Good /
//  Easy). The day is one practice: closing the screen just pauses it, and the next Start continues
//  today's set where it stopped. A card that comes back within the learn-ahead window (a learning
//  step, or a lapse) is queued again — while it has answers left today
//  (`PracticeDay.maxAnswersPerCard`), so a hard card can't loop the day. When today's set is done,
//  "more" adds an extra set of 25. Once the answer is shown, the wand (`cardFix`) sends the card to the
//  model to fix it and fill in what's missing — its texts change on screen and in the rest of the set;
//  its progress and the rating stay the user's.
//

import Foundation
import Domain

@MainActor
@Observable
public final class FlashcardSessionViewModel: Identifiable {
    public enum Phase: Equatable { case loading, studying, finished, failed }

    public let id = UUID()
    public private(set) var phase: Phase = .loading
    public private(set) var current: Flashcard?
    public private(set) var isRevealed = false
    /// Answers given this session.
    public private(set) var reviewedCount = 0
    /// Time until the current card returns, per answer — the labels under the rating buttons.
    public private(set) var intervals: [ReviewRating: TimeInterval] = [:]
    public private(set) var isPlaying = false
    public private(set) var errorMessage: String?
    /// Today against the goal — refreshed at the start and the end of every set.
    public private(set) var plan: DailyPlan?
    /// Fixing the card on screen with the model (the wand); nil when Fix cards isn't wired.
    public let cardFix: CardFixModel?

    private var queue: [Flashcard] = []
    /// Answers per card today — this session's and earlier ones'.
    private var answersToday: [UUID: Int] = [:]
    private var isSaving = false
    private var playTask: Task<Void, Never>?
    private let flashcards: any FlashcardsUseCase
    private let pronounce: any PlayPronunciationUseCase
    private let now: () -> Date
    /// The first set goes beyond today's goal (it's already met).
    private let startsExtra: Bool

    public init(flashcards: any FlashcardsUseCase, pronounce: any PlayPronunciationUseCase, extra: Bool = false,
                fixCards: (any FixCardsUseCase)? = nil, now: @escaping () -> Date = Date.init,
                studiedLanguage: @escaping () -> String = { StudiedLanguage.current.promptName },
                nativeLanguage: @escaping () -> String = { TargetLanguage.current.promptName }) {
        self.flashcards = flashcards
        self.pronounce = pronounce
        self.startsExtra = extra
        self.now = now
        self.cardFix = fixCards.map {
            CardFixModel(fixCards: $0, studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
        }
    }

    /// Cards left, including the one on screen.
    public var remaining: Int { queue.count + (current == nil ? 0 : 1) }

    public func start() async {
        await load(extra: startsExtra)
    }

    /// More practice: up to the goal if it isn't met yet, else an extra set (`DailyPlan.moreSize`).
    public func more() async {
        await load(extra: plan?.goalReached ?? true)
    }

    /// Whether there's anything left to practise today.
    public var canStudyMore: Bool { plan?.hasMore ?? false }

    private func load(extra: Bool) async {
        phase = .loading
        errorMessage = nil
        do {
            queue = try await flashcards.queue(now: now(), extra: extra)
            answersToday = (try? await flashcards.answersToday(now: now())) ?? [:]
            plan = try? await flashcards.stats(now: now()).today
            advance()
        } catch {
            errorMessage = Loc.t("Не удалось загрузить карточки.", "Couldn't load the cards.")
            phase = .failed
        }
    }

    public func reveal() {
        guard phase == .studying, !isRevealed else { return }
        isRevealed = true
    }

    public func rate(_ rating: ReviewRating) {
        guard let card = current, isRevealed, !isSaving else { return }
        isSaving = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isSaving = false }
            do {
                let answeredAt = self.now()
                let next = try await self.flashcards.rate(card.card, rating, now: answeredAt)
                self.reviewedCount += 1
                self.answersToday[next.id, default: 0] += 1
                if next.state == .learning || next.state == .relearning,
                   next.due <= answeredAt.addingTimeInterval(self.flashcards.learnAhead),
                   self.answersToday[next.id, default: 0] < PracticeDay.maxAnswersPerCard {
                    // The texts as they are now: the card may have been fixed while it was on screen.
                    let expression = self.current?.id == card.id ? self.current?.expression : nil
                    self.queue.append(Flashcard(card: next, expression: expression ?? card.expression))
                }
                if self.queue.isEmpty {
                    self.plan = try? await self.flashcards.stats(now: self.now()).today
                }
                self.advance()
            } catch {
                self.errorMessage = Loc.t("Не удалось сохранить ответ. Попробуйте ещё раз.",
                                          "Couldn't save the answer. Try again.")
            }
        }
    }

    /// Speak the studied-language expression (tap again to stop).
    public func play() {
        guard let card = current else { return }
        if isPlaying { stopPlayback(); return }
        isPlaying = true
        playTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await state in self.pronounce(card.expression.en) where state == .finished { break }
            } catch {
                // playback failure is non-fatal
            }
            if !Task.isCancelled { self.isPlaying = false }
        }
    }

    public func clearError() { errorMessage = nil }

    /// The wand: fix the card on screen with the model — once its answer is shown (the prompt mustn't
    /// change under a user still recalling it). The fixed texts replace the card's here and in the
    /// rest of the set (its other direction, its return today).
    public func fixCurrent() {
        guard let cardFix, let card = current, isRevealed else { return }
        cardFix.start(card.expression) { [weak self] fixed in self?.adopt(fixed) }
    }

    private func adopt(_ expression: Domain.Expression) {
        if let card = current, card.expression.id == expression.id {
            current = Flashcard(card: card.card, expression: expression)
        }
        queue = queue.map { $0.expression.id == expression.id ? Flashcard(card: $0.card, expression: expression) : $0 }
    }

    private func advance() {
        stopPlayback()
        cardFix?.clear()   // the next card starts without the last one's status
        isRevealed = false
        guard !queue.isEmpty else {
            current = nil
            intervals = [:]
            phase = .finished
            return
        }
        let next = queue.removeFirst()
        current = next
        intervals = flashcards.previews(for: next.card, now: now())
        phase = .studying
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }

    // MARK: Labels

    /// Compact interval: "<1 min", "10 min", "5 h", "4 d", "3 mo", "2 y".
    public static func intervalLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return Loc.t("<1 мин", "<1 min", "<1 min", "<1 min", "<1 Min.", "<1 min") }
        if minutes < 60 { return Loc.t("\(minutes) мин", "\(minutes) min", "\(minutes) min", "\(minutes) min", "\(minutes) Min.", "\(minutes) min") }
        let hours = Int((seconds / 3_600).rounded())
        if hours < 24 { return Loc.t("\(hours) ч", "\(hours) h", "\(hours) h", "\(hours) h", "\(hours) Std.", "\(hours) h") }
        let days = Int((seconds / 86_400).rounded())
        if days < 30 { return Loc.t("\(days) д", "\(days) d", "\(days) j", "\(days) d", "\(days) T.", "\(days) g") }
        if days < 365 {
            let months = max(1, Int((Double(days) / 30).rounded()))
            return Loc.t("\(months) мес", "\(months) mo", "\(months) mois", "\(months) mes", "\(months) Mon.", "\(months) mesi")
        }
        let years = max(1, Int((Double(days) / 365).rounded()))
        return Loc.t("\(years) г", "\(years) y", "\(years) an", "\(years) a", "\(years) J.", "\(years) a")
    }
}
