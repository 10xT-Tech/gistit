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
    private let now: () -> Date

    public init(flashcards: any FlashcardsUseCase, pronounce: any PlayPronunciationUseCase,
                now: @escaping () -> Date = Date.init) {
        self.flashcards = flashcards
        self.pronounce = pronounce
        self.now = now
    }

    public func load() async {
        if let stats = try? await flashcards.stats(now: now()) { self.stats = stats }
    }

    /// Open a practice session — `extra`: today's goal is met, an extra set beyond it. The paywall
    /// check for the free plan is the view's (it owns the plan).
    public func startPractice(extra: Bool = false) {
        guard session == nil else { return }
        session = FlashcardSessionViewModel(flashcards: flashcards, pronounce: pronounce, extra: extra, now: now)
    }

    /// The session screen closed.
    public func endPractice() {
        session = nil
        Task { await load() }
    }
}
