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

    private func make(_ expressions: [Domain.Expression], clock: Clock) -> (FlashcardSessionViewModel, MockReviewCardRepository) {
        let cards = MockReviewCardRepository()
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
        #expect(try await cards.all().first?.state == .review)
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

    /// The Study screen counts today's cards, opens a session, and re-counts when it closes.
    @Test func studyListEntryCountsAndStartsPractice() async throws {
        let repo = MockExpressionRepository(seed: MockExpressionRepository.defaultSeed)   // one of two learned
        let cards = MockReviewCardRepository()
        let flashcards = FlashcardsInteractor(expressions: repo, cards: cards)
        let vm = StudyListViewModel(
            studyList: StudyListInteractor(repository: repo, cards: cards),
            saveExpression: SaveExpressionInteractor(enrich: EnrichExpressionInteractor(llm: MockLLMClient()),
                                                     repository: repo),
            exportAlgoApp: ExportDeckInteractor(repository: repo, exporter: AlgoAppXMLExporter()),
            exportAnki: ExportDeckInteractor(repository: repo, exporter: AnkiExporter()),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            isConfigured: true,
            flashcards: flashcards
        )
        await vm.load()
        #expect(vm.practice == FlashcardsSummary(due: 0, new: 1))

        vm.startPractice()
        let session = try #require(vm.session)
        await session.start()
        session.reveal()
        session.rate(.easy)                                       // graduates straight to review
        try await waitUntil { session.phase == .finished }

        vm.endPractice()
        #expect(vm.session == nil)
        try await waitUntil { vm.practice?.total == 0 }
        #expect(vm.practice == FlashcardsSummary(due: 0, new: 0))
    }
}
