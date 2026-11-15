//
//  HistoryViewModelTests.swift
//  EnglishHelperTests
//
//  "История" view-models: list load, and saving phrases from the read-only detail.
//

import Testing
import Foundation
import Domain
import Adapters
import Presentation

@Suite @MainActor struct HistoryViewModelTests {

    private func makeListVM(_ repo: MockHistoryRepository) -> HistoryViewModel {
        let exprRepo = MockExpressionRepository(seed: [])
        return HistoryViewModel(
            history: RequestHistoryInteractor(history: repo),
            saveExpression: SaveExpressionInteractor(
                enrich: EnrichExpressionInteractor(llm: MockLLMClient()), repository: exprRepo
            ),
            studyList: StudyListInteractor(repository: exprRepo),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing())
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

    /// Save is optimistic (instant flag); wait for the background enrich+store to land in the repo.
    private func waitUntilStored(_ repo: MockExpressionRepository, en: String,
                                 timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while !(((try? await repo.all()) ?? []).contains { $0.en == en }) {
            if clock.now - start > timeout { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func loadSeededShowsLoaded() async {
        let repo = MockHistoryRepository(seed: [
            HistoryEntry(inputText: "I appreciate it", result: .translate(ru: "Я ценю это")),
            HistoryEntry(inputText: "как сказать привет",
                         result: .howToSay([PhraseVariant(en: "Hi", register: .casual, contextRU: "неформально")])),
        ])
        let vm = makeListVM(repo)
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.entries.count == 2)
    }

    @Test func loadEmptyShowsEmpty() async {
        let vm = makeListVM(MockHistoryRepository(seed: []))
        await vm.load()
        #expect(vm.phase == .empty)
    }

    // MARK: Detail — save into study list

    private func makeDetailVM(entry: HistoryEntry) -> (HistoryDetailViewModel, MockExpressionRepository) {
        let repo = MockExpressionRepository(seed: [])
        let vm = HistoryDetailViewModel(
            entry: entry,
            saveExpression: SaveExpressionInteractor(
                enrich: EnrichExpressionInteractor(llm: MockLLMClient()), repository: repo
            ),
            studyList: StudyListInteractor(repository: repo),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing())
        )
        return (vm, repo)
    }

    @Test func saveVariantFromHowToSayStores() async throws {
        let variant = PhraseVariant(en: "Could you give me a hand?", register: .casual, contextRU: "дружелюбно")
        let entry = HistoryEntry(inputText: "помоги мне", result: .howToSay([variant]))
        let (vm, repo) = makeDetailVM(entry: entry)

        vm.toggleSaveVariant(variant)
        #expect(vm.isSaved(HistoryDetailViewModel.variantKey(variant)))   // optimistic, immediate
        try await waitUntilStored(repo, en: "Could you give me a hand?")
        let all = try await repo.all()
        #expect(all.contains { $0.en == "Could you give me a hand?" })
    }

    @Test func saveTranslationStoresEnglishSource() async throws {
        let entry = HistoryEntry(inputText: "I appreciate it", result: .translate(ru: "Я ценю это"))
        let (vm, repo) = makeDetailVM(entry: entry)

        vm.toggleSaveTranslation()
        #expect(vm.isSaved(HistoryDetailViewModel.translationKey))   // optimistic, immediate
        try await waitUntilStored(repo, en: "I appreciate it")
        let all = try await repo.all()
        #expect(all.contains { $0.en == "I appreciate it" })
    }

    @Test func loadSavedStateReflectsExistingSave() async throws {
        let variant = PhraseVariant(en: "I appreciate it", register: .casual, contextRU: "тепло")
        let entry = HistoryEntry(inputText: "спасибо", result: .howToSay([variant]))
        let repo = MockExpressionRepository(seed: [Domain.Expression(en: "I appreciate it", ru: "Я ценю это")])
        let vm = HistoryDetailViewModel(
            entry: entry,
            saveExpression: SaveExpressionInteractor(
                enrich: EnrichExpressionInteractor(llm: MockLLMClient()), repository: repo
            ),
            studyList: StudyListInteractor(repository: repo),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing())
        )

        await vm.loadSavedState()
        #expect(vm.isSaved(HistoryDetailViewModel.variantKey(variant)))
    }
}

// MARK: - Recording playback errors get their own alert channel

@MainActor struct HistoryDetailPlaybackErrorTests {

    /// A playback failure must land in `playbackError` (its own "Recording" alert) — NEVER in
    /// `errorMessage`, whose alert is titled "Study list".
    @Test func playbackFailureUsesItsOwnChannel() async throws {
        let repo = MockExpressionRepository(seed: [])
        let llm = MockLLMClient()
        let entry = HistoryEntry(
            inputText: "Hi",
            result: .liveTranslation(original: "Hi", ru: "Привет", audioFileName: "s.m4a", duration: 3)
        )
        let vm = HistoryDetailViewModel(
            entry: entry,
            saveExpression: SaveExpressionInteractor(
                enrich: EnrichExpressionInteractor(llm: llm), repository: repo
            ),
            studyList: StudyListInteractor(repository: repo),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            recordings: BusyRecordings()
        )
        #expect(vm.recordingFileName == "s.m4a")

        vm.toggleRecordingPlayback()
        let clock = ContinuousClock(); let start = clock.now
        while vm.playbackError == nil {
            if clock.now - start > .seconds(2) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(vm.playbackError != nil)
        #expect(vm.errorMessage == nil)   // the study-list alert stays silent
    }
}

/// Recordings double whose playback always reports a live session holding the mic.
private struct BusyRecordings: SessionRecordingsManaging {
    func play(fileName: String) -> AsyncThrowingStream<RecordingPlayback, Error> {
        AsyncThrowingStream { $0.finish(throwing: RecordingPlaybackError.busy) }
    }
    func exists(fileName: String) -> Bool { true }
    func delete(fileName: String) async {}
    func sweep(keeping: Set<String>, createdBefore: Date) async {}
}
