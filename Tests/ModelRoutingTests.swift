//
//  ModelRoutingTests.swift
//  EnglishHelper — Tests
//
//  Per-scenario model routing (fixed in AppContainer: Haiku translate / Sonnet explain + Say it):
//  templates honoring their tier, and the interactor passing the provider's tier through.
//

import Testing
import Foundation
import Domain
import Adapters
import Presentation

@Suite struct ModelRoutingTests {

    @Test func templatesRouteToTheirTier() {
        #expect(UnderstandTemplate(tier: .standard).modelTier == .standard)
        #expect(UnderstandTemplate(tier: .fast).modelTier == .fast)
        #expect(ExplainExpressionTemplate(tier: .fast).modelTier == .fast)
        #expect(ExplainExpressionTemplate(tier: .standard).modelTier == .standard)
        #expect(HowToSayTemplate(tier: .fast).modelTier == .fast)
        #expect(HowToSayTemplate(tier: .standard).modelTier == .standard)
        #expect(WhatToSayTemplate(tier: .standard).modelTier == .standard)
    }

    @Test func interactorPassesProviderTierToTemplate() async throws {
        let spy = TierSpyLLMClient(cannedJSON: #"{"studied":"x","variants":[{"text":"y","context":""}]}"#)
        let interactor = UnderstandInteractor(llm: spy, history: MockHistoryRepository(), tier: { .standard })
        _ = try await interactor("hi", studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(spy.captured == .standard)   // the provider's tier reached the template (→ the client)
    }
}

/// Records the model tier the interactor asks for, then returns a canned, schema-valid response.
private final class TierSpyLLMClient: LLMClient, @unchecked Sendable {
    let cannedJSON: String
    private(set) var captured: ModelTier?
    init(cannedJSON: String) { self.cannedJSON = cannedJSON }
    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        captured = template.modelTier
        return try template.decode(cannedJSON)
    }
}
