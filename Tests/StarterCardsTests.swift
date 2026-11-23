//
//  StarterCardsTests.swift
//  EnglishHelperTests
//
//  An empty deck gets five idioms of the studied language when the language pair is chosen or changed:
//  the template, the interactor (only an empty deck, straight into flashcards, a phrase already in Caught
//  enrolled rather than written twice, one run at a time) and the dashboard's trigger.
//

import Testing
import Foundation
import Domain
import Adapters
import Presentation

@Suite @MainActor struct StarterCardsTests {

    @Test func templateAsksForIdiomsOfTheStudiedLanguage() throws {
        let template = StarterCardsTemplate(studiedLanguage: "German", nativeLanguage: "Italian")
        #expect(template.systemPrompt.hasPrefix("Suggest starter cards for an empty flashcard deck."))
        #expect(template.systemPrompt.contains("IDIOMATIC expressions of German"))
        #expect(template.systemPrompt.contains("Italian"))
        #expect(template.userMessage(for: 5) == "Suggest 5 starter cards with German idioms.")
        let result = try template.decode("""
            {"cards":[{"expression":" to break the ice ","translation":"rompere il ghiaccio","example":"e.",
            "synonyms":["a","b","c","d"],"context":"n."},
            {"expression":"","translation":"x","example":"","synonyms":[],"context":""},
            {"expression":"no translation","translation":"","example":"","synonyms":[],"context":""}]}
            """)
        #expect(result.cards.map(\.expression) == ["to break the ice"])
        #expect(result.cards[0].synonyms.count == 3)
    }

    @Test func anEmptyDeckGetsFiveCardsInFlashcards() async throws {
        let caught = Domain.Expression(en: "A piece of cake", ru: "пустяк")
        let repo = MockExpressionRepository(seed: [caught])
        let cards = MockReviewCardRepository()
        let llm = CountingStarterLLM()
        let sut = StarterCardsInteractor(llm: llm, expressions: repo, cards: cards,
                                         flashcards: FlashcardsInteractor(expressions: repo, cards: cards))

        #expect(try await sut.seedIfEmpty(studiedLanguage: "English", nativeLanguage: "Russian") == 5)
        let all = try await repo.all()
        #expect(all.count == 5)                                          // "a piece of cake" not written twice
        #expect(all.contains { $0.id == caught.id })                     // the Caught phrase is the one enrolled
        let enrolled = Set(try await cards.all().map(\.expressionID))
        #expect(enrolled == Set(all.map(\.id)))
        #expect(try await cards.all().count == 10)                       // two directions each
        #expect(all.first { $0.en == "under the weather" }?.context.isEmpty == false)

        // Not empty any more: nothing is asked or added.
        #expect(try await sut.seedIfEmpty(studiedLanguage: "English", nativeLanguage: "Russian") == 0)
        #expect(llm.calls == 1)
    }

    @Test func aDeckWithCardsIsLeftAlone() async throws {
        let phrase = Domain.Expression(en: "jump the gun", ru: "поспешить")
        let repo = MockExpressionRepository(seed: [phrase])
        let cards = MockReviewCardRepository(seed: [ReviewCard(expressionID: phrase.id, direction: .recognition, due: Date())])
        let llm = CountingStarterLLM()
        let sut = StarterCardsInteractor(llm: llm, expressions: repo, cards: cards,
                                         flashcards: FlashcardsInteractor(expressions: repo, cards: cards))
        #expect(try await sut.seedIfEmpty(studiedLanguage: "English", nativeLanguage: "Russian") == 0)
        #expect(llm.calls == 0)
        #expect(try await repo.all().count == 1)
    }

    @Test func aFailedRequestChangesNothing() async throws {
        let repo = MockExpressionRepository(seed: [])
        let cards = MockReviewCardRepository()
        let sut = StarterCardsInteractor(llm: OfflineStarterLLM(), expressions: repo, cards: cards,
                                         flashcards: FlashcardsInteractor(expressions: repo, cards: cards))
        await #expect(throws: LLMError.self) {
            try await sut.seedIfEmpty(studiedLanguage: "English", nativeLanguage: "Russian")
        }
        #expect(try await repo.all().isEmpty)
    }

    /// The dashboard: a change of both languages in a row asks ONCE, for the final pair; the empty
    /// dashboard says it's picking cards meanwhile; the lists are told to reload when cards went in.
    @Test func dashboardAsksOnceForTheFinalPair() async throws {
        let repo = MockExpressionRepository(seed: [])
        let cards = MockReviewCardRepository()
        let llm = CountingStarterLLM()
        let flashcards = FlashcardsInteractor(expressions: repo, cards: cards)
        let sut = StudyDashboardViewModel(
            flashcards: flashcards, pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            starterCards: StarterCardsInteractor(llm: llm, expressions: repo, cards: cards, flashcards: flashcards))
        var reloaded = 0
        sut.seedStarterCards(studiedLanguage: "French", nativeLanguage: "Russian", delay: .milliseconds(50)) { reloaded += 1 }
        sut.seedStarterCards(studiedLanguage: "English", nativeLanguage: "Russian", delay: .milliseconds(50)) { reloaded += 1 }
        await sut.settleStarter()
        #expect(llm.calls == 1)
        #expect(llm.studied == ["English"])
        #expect(reloaded == 1)
        #expect(sut.stats?.inStudy == 5)
        #expect(!sut.preparingStarter)

        // The same language on both sides: nothing to learn, nothing asked.
        sut.seedStarterCards(studiedLanguage: "German", nativeLanguage: "German", delay: .zero)
        await sut.settleStarter()
        #expect(llm.calls == 1)
    }
}

private final class CountingStarterLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var languages: [String] = []
    var calls: Int { lock.withLock { count } }
    var studied: [String] { lock.withLock { languages } }

    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        lock.withLock {
            count += 1
            if let starter = template as? StarterCardsTemplate { languages.append(starter.studiedLanguage) }
        }
        return try await MockLLMClient().run(template, input: input)
    }
}

private struct OfflineStarterLLM: LLMClient {
    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        throw LLMError.offline
    }
}
