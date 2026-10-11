//
//  AnalyticsTests.swift
//  EnglishHelperTests
//
//  Use cases report the RIGHT AnalyticsEvent through the AnalyticsTracking port on success — and
//  nothing on failure. The Amplitude SDK itself is third-party code and is NOT tested here;
//  everything runs against MockAnalyticsTracker.
//

import Testing
import Foundation
import Domain
import Adapters

@Suite struct AnalyticsTests {

    // MARK: Translation completion (the "Get it" Translate flow)

    @Test func translateCompletionTracksTranslateCompleted() async throws {
        let analytics = MockAnalyticsTracker()
        let useCase = UnderstandInteractor(llm: StubLLMClient(behavior: .success, latency: .milliseconds(1)),
                                           history: MockHistoryRepository(), analytics: analytics)
        _ = try await useCase("bank", studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(analytics.events == [.translateCompleted])
    }

    @Test func failedTranslateTracksNothing() async {
        let analytics = MockAnalyticsTracker()
        let useCase = UnderstandInteractor(llm: StubLLMClient(behavior: .malformedJSON, latency: .milliseconds(1)),
                                           history: MockHistoryRepository(), analytics: analytics)
        await #expect(throws: LLMError.self) {
            _ = try await useCase("bank", studiedLanguage: "English", nativeLanguage: "Russian")
        }
        #expect(analytics.events.isEmpty)
    }

    /// A cache HIT is still a completed feature use — the contract is "one event per completion",
    /// whether or not the model was called.
    @Test func cacheHitStillTracksTranslateCompleted() async throws {
        let analytics = MockAnalyticsTracker()
        let useCase = UnderstandInteractor(llm: MockLLMClient(), history: MockHistoryRepository(),
                                           cache: MockTranslationCache(), analytics: analytics)
        _ = try await useCase("bank", studiedLanguage: "English", nativeLanguage: "Russian")   // miss → LLM
        _ = try await useCase("bank", studiedLanguage: "English", nativeLanguage: "Russian")   // hit → cache
        #expect(analytics.events == [.translateCompleted, .translateCompleted])
    }

    // MARK: The other LLM flows report their own events (each case pinned, so a copy-paste
    // event swap in an interactor can't slip through)

    @Test func howToSayTracksSayItCompleted() async throws {
        let analytics = MockAnalyticsTracker()
        let useCase = HowToSayInteractor(llm: StubLLMClient(behavior: .success, latency: .milliseconds(1)),
                                         history: MockHistoryRepository(), analytics: analytics)
        _ = try await useCase("как сказать спасибо")
        #expect(analytics.events == [.sayItCompleted])
    }

    @Test func regenerateTracksSayItRegenerated() async throws {
        let analytics = MockAnalyticsTracker()
        let useCase = RegenerateHowToSayInteractor(llm: MockLLMClient(),
                                                   history: MockHistoryRepository(), analytics: analytics)
        _ = try await useCase("как сказать спасибо")
        #expect(analytics.events == [.sayItRegenerated])
    }

    @Test func whatToSayTracksWhatToSayCompleted() async throws {
        let analytics = MockAnalyticsTracker()
        let useCase = WhatToSayInteractor(llm: MockLLMClient(),
                                          history: MockHistoryRepository(), analytics: analytics)
        _ = try await useCase("приём у врача")
        #expect(analytics.events == [.whatToSayCompleted])
    }

    @Test func explainTracksExplainCompleted() async throws {
        let analytics = MockAnalyticsTracker()
        let useCase = ExplainExpressionInteractor(llm: MockLLMClient(), analytics: analytics)
        _ = try await useCase("break a leg", studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(analytics.events == [.explainCompleted])
    }

    @Test func photoTranslateTracksPhotoTranslateCompleted() async throws {
        let analytics = MockAnalyticsTracker()
        let useCase = PhotoTranslateInteractor(llm: MockLLMClient(),
                                               history: MockHistoryRepository(), analytics: analytics)
        _ = try await useCase(RecognizableImage(data: Data()))
        #expect(analytics.events == [.photoTranslateCompleted])
    }

    @Test func photoExplainTracksPhotoExplainCompleted() async throws {
        let analytics = MockAnalyticsTracker()
        let useCase = PhotoExplainInteractor(llm: MockLLMClient(), history: MockHistoryRepository(),
                                             analytics: analytics)
        _ = try await useCase(RecognizableImage(data: Data()), studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(analytics.events == [.photoExplainCompleted])
    }

    // MARK: Library events

    @Test func savingNewExpressionTracksExpressionSaved() async throws {
        let analytics = MockAnalyticsTracker()
        let save = SaveExpressionInteractor(enrich: EnrichExpressionInteractor(llm: MockLLMClient()),
                                            repository: MockExpressionRepository(seed: []),
                                            analytics: analytics)
        _ = try await save(en: "give me a hand", knownRU: nil, context: "")
        #expect(analytics.events == [.expressionSaved])
    }

    @Test func deduplicatedSaveTracksNothing() async throws {
        let analytics = MockAnalyticsTracker()
        let repository = MockExpressionRepository()   // default seed contains "I appreciate it"
        let save = SaveExpressionInteractor(enrich: EnrichExpressionInteractor(llm: MockLLMClient()),
                                            repository: repository, analytics: analytics)
        _ = try await save(en: "I appreciate it", knownRU: nil, context: "")
        #expect(analytics.events.isEmpty)
    }

    @Test func exportTracksDeckExported() async throws {
        let analytics = MockAnalyticsTracker()
        let export = ExportDeckInteractor(repository: MockExpressionRepository(),
                                          exporter: MockDeckExporting(), analytics: analytics)
        _ = try await export()
        #expect(analytics.events == [.deckExported])
    }

    // MARK: The port stays optional — use cases run fine with analytics disabled

    @Test func useCasesRunWithoutAnalytics() async throws {
        let useCase = UnderstandInteractor(llm: MockLLMClient(), history: MockHistoryRepository())
        let result = try await useCase("bank", studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(!result.variants.isEmpty)
    }
}
