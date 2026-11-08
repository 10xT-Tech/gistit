//
//  StudyListViewModelTests.swift
//  EnglishHelperTests
//
//  "Изучаю" view-model: load, manual add (enrich-then-store), delete, toggle learned, export.
//

import Testing
import Foundation
import Domain
import Adapters
import Presentation

@Suite @MainActor struct StudyListViewModelTests {

    private func makeVM(seed: [Domain.Expression]) -> StudyListViewModel {
        let repo = MockExpressionRepository(seed: seed)
        return StudyListViewModel(
            studyList: StudyListInteractor(repository: repo),
            saveExpression: SaveExpressionInteractor(
                enrich: EnrichExpressionInteractor(llm: MockLLMClient()), repository: repo
            ),
            exportAlgoApp: ExportDeckInteractor(repository: repo, exporter: AlgoAppXMLExporter()),
            exportAnki: ExportDeckInteractor(repository: repo, exporter: AnkiExporter()),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            isConfigured: true
        )
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while !condition() {
            if clock.now - start > timeout { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func loadSeededShowsLoaded() async {
        let vm = makeVM(seed: MockExpressionRepository.defaultSeed)
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.expressions.count == 2)
    }

    @Test func loadEmptyShowsEmpty() async {
        let vm = makeVM(seed: [])
        await vm.load()
        #expect(vm.phase == .empty)
    }

    @Test func addEnrichesAndAppears() async throws {
        let vm = makeVM(seed: [])
        await vm.load()
        vm.newEnglish = "I appreciate it"
        vm.add()
        try await waitUntil { vm.expressions.count == 1 }
        let added = try #require(vm.expressions.first)
        #expect(added.ru.isEmpty == false)        // enriched
        #expect(added.example.isEmpty == false)
    }

    @Test func deleteRemovesImmediately() async throws {
        let vm = makeVM(seed: MockExpressionRepository.defaultSeed)
        await vm.load()
        let first = try #require(vm.expressions.first)
        vm.delete(first)
        #expect(vm.expressions.contains { $0.id == first.id } == false)
    }

    /// Moving to flashcards takes the expression off this list (at once and in the store) and gives
    /// it its two cards; without flashcards wired the action isn't offered.
    @Test func moveToFlashcardsLeavesTheList() async throws {
        let repo = MockExpressionRepository(seed: MockExpressionRepository.defaultSeed)
        let cards = MockReviewCardRepository()
        let vm = StudyListViewModel(
            studyList: StudyListInteractor(repository: repo, cards: cards),
            saveExpression: SaveExpressionInteractor(
                enrich: EnrichExpressionInteractor(llm: MockLLMClient()), repository: repo
            ),
            exportAlgoApp: ExportDeckInteractor(repository: repo, exporter: AlgoAppXMLExporter()),
            exportAnki: ExportDeckInteractor(repository: repo, exporter: AnkiExporter()),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            isConfigured: true,
            flashcards: FlashcardsInteractor(expressions: repo, cards: cards)
        )
        await vm.load()
        #expect(vm.canMoveToFlashcards)
        let first = try #require(vm.expressions.first)
        vm.moveToFlashcards(first)
        #expect(!vm.expressions.contains { $0.id == first.id })
        try await waitUntil { vm.expressions.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await cards.all().filter { $0.expressionID == first.id }.count == 2)
        await vm.load()
        #expect(!vm.expressions.contains { $0.id == first.id })
        #expect(vm.actionError == nil)

        #expect(!makeVM(seed: []).canMoveToFlashcards)
    }

    @Test func exportProducesXMLDeck() async throws {
        let vm = makeVM(seed: MockExpressionRepository.defaultSeed)
        await vm.load()
        vm.export(.algoApp)
        try await waitUntil { vm.exportedDeck != nil }
        #expect(vm.exportedDeck?.filename.hasSuffix(".xml") == true)
    }

    @Test func exportAnkiProducesTxtDeck() async throws {
        let vm = makeVM(seed: MockExpressionRepository.defaultSeed)
        await vm.load()
        vm.export(.anki)
        try await waitUntil { vm.exportedDeck != nil }
        #expect(vm.exportedDeck?.filename.hasSuffix(".txt") == true)
    }

    @Test func exportEmptyListSetsError() async throws {
        let vm = makeVM(seed: [])
        await vm.load()
        vm.export(.algoApp)
        try await waitUntil { vm.exportError != nil }
        #expect(vm.exportError != nil)
    }
}
