//
//  SubscriptionTierTests.swift
//  EnglishHelperTests
//
//  Free-plan rules are decided per SCENARIO: translations free, explanations + Say it rationed, live
//  translation subscriber-only. The backend tells translations apart by the fixed opening of their
//  system prompt (Backend/src/validate.mjs FREE_PROMPT_OPENINGS) — these tests pin that contract.
//

import Testing
import Foundation
import Domain

@Suite struct SubscriptionTierTests {

    /// Must equal FREE_PROMPT_OPENINGS in Backend/src/validate.mjs.
    private static let freeOpenings = [
        "The user wants to understand some text.",
        "You read text from a photo.",
        "Enrich an English expression for a study card.",
    ]

    private static func isFree(_ systemPrompt: String) -> Bool {
        freeOpenings.contains { systemPrompt.hasPrefix($0) }
    }

    @Test func translationsAreRecognisedAsFree() {
        for (studied, native) in [("English", "Russian"), ("German", "French"), ("Italian", "Spanish")] {
            #expect(Self.isFree(UnderstandTemplate(studiedLanguage: studied, nativeLanguage: native).systemPrompt))
            #expect(Self.isFree(PhotoBlocksTemplate(studiedLanguage: studied, nativeLanguage: native).systemPrompt))
        }
        #expect(Self.isFree(EnrichCardTemplate().systemPrompt))
    }

    @Test func explanationsAndSayItAreMetered() {
        for (studied, native) in [("English", "Russian"), ("German", "French")] {
            #expect(!Self.isFree(ExplainExpressionTemplate(studiedLanguage: studied, nativeLanguage: native).systemPrompt))
            #expect(!Self.isFree(PhotoExplainTemplate(studiedLanguage: studied, nativeLanguage: native).systemPrompt))
            for tone in [Register.formal, .casual, .slang] {
                #expect(!Self.isFree(HowToSayTemplate(tone: tone, studiedLanguage: studied, nativeLanguage: native).systemPrompt))
                #expect(!Self.isFree(WhatToSayTemplate(tone: tone, studiedLanguage: studied, nativeLanguage: native).systemPrompt))
            }
        }
    }

    @Test func tierFlags() {
        #expect(AccessTier.free.hasUnlimitedExplanations == false)
        #expect(AccessTier.free.canUseLiveTranslation == false)
        #expect(AccessTier.free.offersSubscription)
        #expect(AccessTier.subscribed(expires: nil).hasUnlimitedExplanations)
        #expect(AccessTier.subscribed(expires: nil).canUseLiveTranslation)
        #expect(AccessTier.unlimited.canUseLiveTranslation)
        #expect(AccessTier.unlimited.offersSubscription == false)   // TestFlight / Xcode: no paywall
    }

    @Test func aFreePlanLimitStillCountsAsAHealthyConnection() async {
        struct Limited: LLMClient {
            func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
                throw LLMError.subscriptionRequired(retryAfter: 60)
            }
        }
        #expect(await ConnectionHealthInteractor(llm: Limited())(.standard) == .ok)
    }
}
