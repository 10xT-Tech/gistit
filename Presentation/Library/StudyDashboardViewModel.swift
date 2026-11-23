//
//  StudyDashboardViewModel.swift
//  EnglishHelper — Presentation
//
//  The Study tab's dashboard: today's practice, how many expressions are in flashcards and saved for
//  later, how the cards are distributed by stage, and answers per day — plus the practice session.
//

import Foundation
import Domain

@MainActor
@Observable
public final class StudyDashboardViewModel {
    /// Nil until the first load (or when it failed — the dashboard then shows what it can).
    public private(set) var stats: StudyStats?
    /// The practice session on screen (presented full screen while non-nil).
    public var session: FlashcardSessionViewModel?

    private let flashcards: any FlashcardsUseCase
    private let pronounce: any PlayPronunciationUseCase
    /// For the wand on a card in practice (fix it with the model); nil = no wand.
    private let fixCards: (any FixCardsUseCase)?
    /// Starter cards for an empty deck when the language pair is chosen or changed; nil = none.
    private let starterCards: (any StarterCardsUseCase)?
    private let now: () -> Date
    /// The pending / running starter request (a new language change replaces a pending one).
    private var starterTask: Task<Void, Never>?
    /// Starter cards are being asked for: the empty dashboard says so.
    public private(set) var preparingStarter = false

    public init(flashcards: any FlashcardsUseCase, pronounce: any PlayPronunciationUseCase,
                fixCards: (any FixCardsUseCase)? = nil, starterCards: (any StarterCardsUseCase)? = nil,
                now: @escaping () -> Date = Date.init) {
        self.flashcards = flashcards
        self.pronounce = pronounce
        self.fixCards = fixCards
        self.starterCards = starterCards
        self.now = now
    }

    /// The language pair was chosen or changed: if flashcards are empty, ask the model for a few idioms
    /// of the studied language and put them in. After `delay`, so changing both languages one after the
    /// other asks once, for the final pair. `onAdded` runs when cards went in (the lists reload).
    /// A failure — offline, the plan, no answer — leaves the deck as it was; the next change tries again.
    public func seedStarterCards(studiedLanguage: String, nativeLanguage: String,
                                 delay: Duration = .seconds(1), onAdded: @escaping @MainActor () async -> Void = {}) {
        guard let starterCards, studiedLanguage != nativeLanguage else { return }
        starterTask?.cancel()
        starterTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.preparingStarter = true
            defer { self.preparingStarter = false }
            let added = (try? await starterCards.seedIfEmpty(studiedLanguage: studiedLanguage,
                                                             nativeLanguage: nativeLanguage)) ?? 0
            guard added > 0 else { return }
            await self.load()
            await onAdded()
        }
    }

    /// Waits for the starter request under way (tests).
    public func settleStarter() async { await starterTask?.value }

    public func load() async {
        if let stats = try? await flashcards.stats(now: now()) { self.stats = stats }
    }

    /// Open a practice session — `extra`: today's goal is met, an extra set beyond it. The paywall
    /// check for the free plan is the view's (it owns the plan).
    public func startPractice(extra: Bool = false) {
        guard session == nil else { return }
        session = FlashcardSessionViewModel(flashcards: flashcards, pronounce: pronounce, extra: extra,
                                            fixCards: fixCards, now: now)
    }

    /// The session screen closed.
    public func endPractice() {
        session = nil
        Task { await load() }
    }
}
