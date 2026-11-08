//
//  FlashcardSessionViewModel.swift
//  EnglishHelper — Presentation
//
//  One practice session: a set sized by the daily goal, card by card — show the prompt, reveal the
//  answer, rate it (Again / Hard / Good / Easy). A card that comes back within the learn-ahead window
//  (a learning step, or a lapse) is queued again at the end of this session — at most
//  `maxShowings` times in all, so a hard card can't loop the session; it returns next time. When the
//  set is done, "more" brings another goal-sized set.
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

    /// How many times one card may be shown in a session.
    public static let maxShowings = 3

    private var queue: [Flashcard] = []
    private var showings: [UUID: Int] = [:]
    private var isSaving = false
    private var playTask: Task<Void, Never>?
    private let flashcards: any FlashcardsUseCase
    private let pronounce: any PlayPronunciationUseCase
    private let now: () -> Date
    /// The first set goes beyond today's goal (it's already met).
    private let startsExtra: Bool

    public init(flashcards: any FlashcardsUseCase, pronounce: any PlayPronunciationUseCase, extra: Bool = false,
                now: @escaping () -> Date = Date.init) {
        self.flashcards = flashcards
        self.pronounce = pronounce
        self.startsExtra = extra
        self.now = now
    }

    /// Cards left, including the one on screen.
    public var remaining: Int { queue.count + (current == nil ? 0 : 1) }

    public func start() async {
        await load(extra: startsExtra)
    }

    /// Another goal-sized set beyond today's goal.
    public func more() async {
        await load(extra: true)
    }

    /// Whether another set has cards to offer.
    public var canStudyMore: Bool { (plan?.available.total ?? 0) > 0 }

    private func load(extra: Bool) async {
        phase = .loading
        errorMessage = nil
        do {
            queue = try await flashcards.queue(now: now(), extra: extra)
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
                if next.state == .learning || next.state == .relearning,
                   next.due <= answeredAt.addingTimeInterval(self.flashcards.learnAhead),
                   self.showings[next.id, default: 0] < Self.maxShowings {
                    self.queue.append(Flashcard(card: next, expression: card.expression))
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

    private func advance() {
        stopPlayback()
        isRevealed = false
        guard !queue.isEmpty else {
            current = nil
            intervals = [:]
            phase = .finished
            return
        }
        let next = queue.removeFirst()
        showings[next.id, default: 0] += 1
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
