//
//  UseCaseContractTests.swift
//  EnglishHelperTests
//
//  Use-case behavior against a stub LLM (success / malformed / timeout), the history-append
//  contract, and the enrich plain-text contract.
//

import Testing
import Foundation
import Domain
import Adapters

@Suite struct UseCaseContractTests {

    // MARK: LLM request use cases vs a stub LLM

    @Test func howToSaySucceedsOnStub() async throws {
        let useCase = HowToSayInteractor(llm: StubLLMClient(behavior: .success, latency: .milliseconds(1)),
                                         history: MockHistoryRepository())
        let variants = try await useCase("как сказать спасибо")
        #expect(variants.count == 3)
    }

    // MARK: Per-template model settings (output budget + speed profile)

    @Test func shortTextTemplatesUseFastDefaults() {
        // Text tasks default to the smaller budget + fast profile so the adapter can pick low effort
        // — optimizing response speed (the budget still leaves room for adaptive thinking).
        #expect(HowToSayTemplate().maxOutputTokens == 8192)
        #expect(HowToSayTemplate().prefersFastResponse)
        #expect(WhatToSayTemplate().prefersFastResponse)
        #expect(UnderstandTemplate().prefersFastResponse)
        #expect(ExplainExpressionTemplate().prefersFastResponse)
    }

    @Test func photoTemplateGetsLargerBudgetAndAccuracyProfile() {
        // A photo can carry a LOT of text (a full menu) — it needs a bigger output budget so the JSON
        // isn't truncated, and leans toward accuracy rather than the fast text profile.
        #expect(PhotoBlocksTemplate().maxOutputTokens == 16384)
        #expect(PhotoBlocksTemplate().maxOutputTokens > HowToSayTemplate().maxOutputTokens)
        #expect(PhotoBlocksTemplate().prefersFastResponse == false)
    }

    @Test func translateThrowsOnMalformedJSON() async {
        let useCase = UnderstandInteractor(llm: StubLLMClient(behavior: .malformedJSON, latency: .milliseconds(1)),
                                           history: MockHistoryRepository())
        await #expect(throws: LLMError.self) {
            _ = try await useCase("hello", studiedLanguage: "English", nativeLanguage: "Russian")
        }
    }

    @Test func translateThrowsOnTimeout() async {
        let useCase = UnderstandInteractor(llm: StubLLMClient(behavior: .timeout, latency: .milliseconds(1)),
                                           history: MockHistoryRepository())
        await #expect(throws: LLMError.self) {
            _ = try await useCase("hello", studiedLanguage: "English", nativeLanguage: "Russian")
        }
    }

    // MARK: History-append contract — exactly one on success, zero on failure

    @Test func appendsExactlyOneHistoryEntryOnSuccess() async throws {
        let history = MockHistoryRepository()
        let useCase = HowToSayInteractor(llm: StubLLMClient(behavior: .success, latency: .milliseconds(1)),
                                         history: history)
        _ = try await useCase("привет")
        let entries = try await history.recent(limit: 10)
        #expect(entries.count == 1)
        #expect(entries.first?.kind == .howToSay)
    }

    @Test func appendsZeroHistoryEntriesOnFailure() async throws {
        let history = MockHistoryRepository()
        let useCase = HowToSayInteractor(llm: StubLLMClient(behavior: .malformedJSON, latency: .milliseconds(1)),
                                         history: history)
        await #expect(throws: LLMError.self) { _ = try await useCase("привет") }
        let entries = try await history.recent(limit: 10)
        #expect(entries.isEmpty)
    }

    // MARK: Enrich plain-text contract — no markdown/symbols, 0–3 synonyms

    @Test func enrichStripsMarkdownAndClampsSynonyms() throws {
        let dirty = #"""
        {"ru":"**жирный** текст","example":"He `really` said hi #now","synonyms":["one","*two*","three","four","five"]}
        """#
        let result = try EnrichCardTemplate().decode(dirty)

        #expect(!PlainText.hasDecoration(result.ru))
        #expect(!PlainText.hasDecoration(result.example))
        #expect(result.synonyms.count <= 3)
        #expect(result.synonyms.allSatisfy { !PlainText.hasDecoration($0) })
        #expect(result.synonyms.allSatisfy { !$0.isEmpty })
    }

    // MARK: Per-language flow parametrization

    /// "Say it": variants are produced in the STUDIED language; notes in the NATIVE language.
    @Test func howToSayTemplateInjectsStudiedAndNative() {
        let prompt = HowToSayTemplate(tone: .casual, studiedLanguage: "English", nativeLanguage: "French").systemPrompt
        #expect(prompt.contains("French speaker who is learning English"))   // native learner of studied
        #expect(prompt.contains("English variants"))                          // variants in studied
        #expect(prompt.contains("note IN French"))                            // notes in native
    }

    /// "What to say": situation → relevance-driven phrase set (3–10), in studied + native.
    @Test func whatToSayTemplateInjectsLanguagesAndAllowsThreeToTen() {
        let template = WhatToSayTemplate(tone: .casual, studiedLanguage: "English", nativeLanguage: "French")
        let prompt = template.systemPrompt
        #expect(prompt.contains("French speaker who is learning English"))   // native learner of studied
        #expect(prompt.contains("SITUATION"))                                // situation-driven, not one phrase
        #expect(prompt.contains("AT LEAST 3 and AT MOST 10"))                // relevance-driven count
        #expect(template.outputJSONSchema.contains("\"additionalProperties\":false"))   // structured-output ready
    }

    /// The decoder honors the 10-max even if the model overshoots.
    @Test func whatToSayDecodeClampsToTen() throws {
        let items = (1...14).map { #"{"en":"phrase \#($0)","register":"casual","context_ru":"нота"}"# }
        let json = "{\"variants\":[\(items.joined(separator: ","))]}"
        let result = try WhatToSayTemplate().decode(json)
        #expect(result.variants.count == 10)
    }

    /// "See it": each photo block is rendered in BOTH the studied and the native language.
    @Test func photoBlocksTemplateInjectsStudiedAndNative() {
        let prompt = PhotoBlocksTemplate(studiedLanguage: "Spanish", nativeLanguage: "Russian").systemPrompt
        #expect(prompt.contains("Spanish"))          // "en" rendering = studied
        #expect(prompt.contains("Russian"))          // "ru" rendering = native
        #expect(prompt.contains("ANY language"))     // source detected, not assumed English
    }
}
