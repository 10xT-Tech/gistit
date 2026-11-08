//
//  FlashcardSessionViewModelTests.swift
//  EnglishHelperTests
//
//  A practice session: reveal before rating, learning steps come back within the session, the
//  session ends when the queue is empty, and the Study screen's entry (counts, start, refresh).
//

import Testing
import Foundation
import Domain
import Adapters
import Presentation

@Suite @MainActor struct FlashcardSessionViewModelTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A clock the test moves forward (a learning step is minutes away).
    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    /// A session over `expressions`, all already moved into flashcards.
    private func make(_ expressions: [Domain.Expression], clock: Clock) -> (FlashcardSessionViewModel, MockReviewCardRepository) {
        let cards = MockReviewCardRepository(seed: expressions.flatMap { e in
            CardDirection.allCases.map { ReviewCard(expressionID: e.id, direction: $0, due: start) }
        })
        let flashcards = FlashcardsInteractor(expressions: MockExpressionRepository(seed: expressions), cards: cards)
        let vm = FlashcardSessionViewModel(flashcards: flashcards,
                                           pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
                                           now: { clock.now })
        return (vm, cards)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let begin = clock.now
        while !condition() {
            if clock.now - begin > timeout { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// New card: Good → the 10-minute step comes back in this session; Good again graduates it and
    /// the session ends.
    @Test func learningStepReturnsWithinTheSession() async throws {
        let clock = Clock(start)
        let (vm, cards) = make([Domain.Expression(en: "break the ice", ru: "растопить лёд",
                                                  createdAt: start.addingTimeInterval(-86_400))], clock: clock)
        await vm.start()
        #expect(vm.phase == .studying)
        #expect(vm.remaining == 1)
        #expect(vm.current?.card.direction == .recognition)
        #expect(vm.intervals[.good] == 600)

        vm.rate(.good)                                            // not revealed yet → ignored
        #expect(vm.reviewedCount == 0)

        vm.reveal()
        vm.rate(.good)
        try await waitUntil { vm.reviewedCount == 1 }
        #expect(vm.phase == .studying)                            // the same card, next step
        #expect(vm.current?.card.state == .learning)
        #expect(!vm.isRevealed)

        clock.now = start.addingTimeInterval(600)
        vm.reveal()
        vm.rate(.good)
        try await waitUntil { vm.phase == .finished }
        #expect(vm.reviewedCount == 2)
        #expect(try await cards.all().first { $0.direction == .recognition }?.state == .review)
    }

    @Test func emptyQueueFinishesAtOnce() async {
        let (vm, _) = make([], clock: Clock(start))
        await vm.start()
        #expect(vm.phase == .finished)
        #expect(vm.reviewedCount == 0)
    }

    @Test func intervalLabelsUseTheLargestFittingUnit() {
        #expect(FlashcardSessionViewModel.intervalLabel(600).contains("10"))
        #expect(FlashcardSessionViewModel.intervalLabel(4 * 86_400).contains("4"))
        #expect(FlashcardSessionViewModel.intervalLabel(90 * 86_400).contains("3"))
    }

    /// Saved for later → moved into flashcards → the dashboard counts it, a session practises it, and
    /// the dashboard re-counts when the session closes.
    @Test func moveToFlashcardsThenPracticeFromTheDashboard() async throws {
        let repo = MockExpressionRepository(seed: MockExpressionRepository.defaultSeed)
        let cards = MockReviewCardRepository()
        let flashcards = FlashcardsInteractor(expressions: repo, cards: cards)
        let pronounce = PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing())
        let list = StudyListViewModel(
            studyList: StudyListInteractor(repository: repo, cards: cards),
            saveExpression: SaveExpressionInteractor(enrich: EnrichExpressionInteractor(llm: MockLLMClient()),
                                                     repository: repo),
            exportAlgoApp: ExportDeckInteractor(repository: repo, exporter: AlgoAppXMLExporter()),
            exportAnki: ExportDeckInteractor(repository: repo, exporter: AnkiExporter()),
            pronounce: pronounce,
            isConfigured: true,
            flashcards: flashcards
        )
        let dashboard = StudyDashboardViewModel(flashcards: flashcards, pronounce: pronounce)

        await list.load()
        #expect(list.expressions.count == 2)                      // everything starts saved for later
        await dashboard.load()
        #expect(dashboard.stats?.inStudy == 0)
        #expect(dashboard.stats?.saved == 2)

        let phrase = try #require(list.expressions.first)
        list.moveToFlashcards(phrase)
        #expect(list.expressions.count == 1)                      // leaves the list at once
        var tries = 0
        while try await cards.all().count != 2, tries < 200 {
            tries += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        await dashboard.load()
        #expect(dashboard.stats?.inStudy == 1)
        #expect(dashboard.stats?.saved == 1)
        #expect(dashboard.stats?.today == FlashcardsSummary(due: 0, new: 1))
        await list.load()
        #expect(!list.expressions.contains { $0.id == phrase.id })

        dashboard.startPractice()
        let session = try #require(dashboard.session)
        await session.start()
        session.reveal()
        session.rate(.easy)                                       // graduates straight to review
        try await waitUntil { session.phase == .finished }

        dashboard.endPractice()
        #expect(dashboard.session == nil)
        try await waitUntil { dashboard.stats?.today.total == 0 }
        #expect(dashboard.stats?.reviewsToday == 1)
        #expect(dashboard.stats?.distribution.young == 1)
    }
}
