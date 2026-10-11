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

    @Test func toggleLearnedFlips() async throws {
        let vm = makeVM(seed: MockExpressionRepository.defaultSeed)
        await vm.load()
        let first = try #require(vm.expressions.first)
        let before = first.learned
        vm.toggleLearned(first)
        let updated = try #require(vm.expressions.first { $0.id == first.id })
        #expect(updated.learned == !before)
    }

    @Test func cleanUpRemovesOnlyLearnedAndPersists() async throws {
        let vm = makeVM(seed: MockExpressionRepository.defaultSeed)
        await vm.load()
        let total = vm.expressions.count
        let first = try #require(vm.expressions.first)
        if !first.learned { vm.toggleLearned(first) }
        let learnedBefore = vm.learnedCount
        #expect(learnedBefore >= 1)

        vm.cleanUpLearned()
        // Optimistic: the learned rows are gone at once, nothing else is touched.
        #expect(vm.learnedCount == 0)
        #expect(vm.expressions.count == total - learnedBefore)
        #expect(vm.expressions.contains { $0.id == first.id } == false)

        // Persisted: a fresh load from the store agrees.
        try await Task.sleep(for: .milliseconds(100))
        await vm.load()
        #expect(vm.expressions.count == total - learnedBefore)
        #expect(vm.expressions.contains { $0.id == first.id } == false)
    }

    @Test func cleanUpWithNothingLearnedIsNoOp() async throws {
        let vm = makeVM(seed: MockExpressionRepository.defaultSeed)
        await vm.load()
        for e in vm.expressions where e.learned { vm.toggleLearned(e) }
        let count = vm.expressions.count
        #expect(vm.learnedCount == 0)
        vm.cleanUpLearned()
        #expect(vm.expressions.count == count)
        #expect(vm.phase == .loaded)
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
