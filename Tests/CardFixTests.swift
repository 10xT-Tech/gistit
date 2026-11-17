//
//  CardFixTests.swift
//  EnglishHelperTests
//
//  The wand on a flashcard — fix ONE card with the model: the use case (always sent, filled in and
//  stored, the progress untouched; a failure changes nothing), `CardFixModel`'s status (fixing →
//  updated / nothing to change / failed, with the subscription offered at the plan's limit, tied to
//  its card), practice (only once the answer is shown; the texts change on screen and when the card
//  comes back) and the In-flashcards card view (the row is replaced).
//

import Testing
import Foundation
import Domain
import Adapters
import Presentation

@Suite struct CardFixTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func lacking(_ en: String = "phrase") -> Domain.Expression {
        Domain.Expression(en: en, ru: "фраза", createdAt: now.addingTimeInterval(-86_400))
    }

    private var complete: Domain.Expression {
        Domain.Expression(en: "jump the gun", ru: "поторопиться", example: "don't jump the gun.",
                          synonyms: ["rush"], context: "разговорное.", createdAt: now.addingTimeInterval(-86_400))
    }

    private func newCards(_ e: Domain.Expression) -> [ReviewCard] {
        CardDirection.allCases.map { ReviewCard(expressionID: e.id, direction: $0, due: now.addingTimeInterval(-3_600)) }
    }

    private func fixer(_ llm: any LLMClient, _ expressions: MockExpressionRepository,
                       _ cards: MockReviewCardRepository = MockReviewCardRepository()) -> FixCardsInteractor {
        FixCardsInteractor(llm: llm, expressions: expressions, cards: cards)
    }

    // MARK: Use case

    /// What's missing is filled in and stored; a complete card is sent all the same (the user asked)
    /// and comes back as it was; the learning progress isn't touched.
    @Test func fixFillsInAndStores() async throws {
        let card = lacking(), full = complete
        let expressions = MockExpressionRepository(seed: [card, full])
        let seeded = newCards(card)
        let cards = MockReviewCardRepository(seed: seeded)
        let spy = CountingFixLLM()
        let sut = fixer(spy, expressions, cards)

        let fixed = try await sut.fix(card, studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(fixed.id == card.id && !FixCardsInteractor.needsCompletion(fixed))
        #expect(try await expressions.all().first { $0.id == card.id } == fixed)
        #expect(Set(try await cards.all()) == Set(seeded))         // the progress untouched

        let same = try await sut.fix(full, studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(same == full)
        #expect(spy.calls == 2)                                    // sent both times
    }

    /// The plan's limit, or an answer without the card: it throws and nothing is changed.
    @Test func aFailedFixChangesNothing() async throws {
        let card = lacking()
        let expressions = MockExpressionRepository(seed: [card])
        await #expect(throws: LLMError.self) {
            _ = try await fixer(FailingLLM(.subscriptionRequired(retryAfter: 240)), expressions)
                .fix(card, studiedLanguage: "English", nativeLanguage: "Russian")
        }
        await #expect(throws: LLMError.self) {
            _ = try await fixer(ForgetfulLLM(), expressions).fix(card, studiedLanguage: "English", nativeLanguage: "Russian")
        }
        #expect(try await expressions.all() == [card])
    }

    // MARK: Status

    @MainActor private func model(_ llm: any LLMClient, _ expressions: MockExpressionRepository) -> CardFixModel {
        CardFixModel(fixCards: fixer(llm, expressions), studiedLanguage: { "English" }, nativeLanguage: { "Russian" })
    }

    @MainActor @Test func theStatusFollowsTheRequestAndItsCard() async throws {
        let card = lacking(), full = complete
        let expressions = MockExpressionRepository(seed: [card, full])
        let sut = model(MockLLMClient(), expressions)
        #expect(sut.status(for: card) == nil)

        let fixed = try #require(await sut.fix(card))
        #expect(sut.status(for: fixed) == .updated)
        #expect(sut.status(for: full) == nil)                      // never on another card
        #expect(await sut.fix(full) == full)
        #expect(sut.status(for: full) == .unchanged && sut.status(for: card) == nil)
        sut.clear()
        #expect(sut.status(for: full) == nil)

        let limited = model(FailingLLM(.subscriptionRequired(retryAfter: 240)), expressions)
        #expect(await limited.fix(card) == nil)
        guard case .failed(let message, let needsSubscription)? = limited.status(for: card) else {
            Issue.record("expected a failure"); return
        }
        #expect(needsSubscription && !message.isEmpty)             // "Subscribe" is offered

        let offline = model(FailingLLM(.offline), expressions)
        #expect(await offline.fix(card) == nil)
        guard case .failed(_, let offered)? = offline.status(for: card) else { Issue.record("expected a failure"); return }
        #expect(!offered)
    }

    // MARK: Practice

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// In practice the wand works once the answer is shown; the fixed texts are on screen at once and
    /// when the card comes back the same day; the card's progress is the rating's business, not the fix's.
    @MainActor @Test func fixingTheCardOnScreen() async throws {
        let card = lacking()
        let expressions = MockExpressionRepository(seed: [card])
        let cards = MockReviewCardRepository(seed: newCards(card))
        let spy = CountingFixLLM()
        let vm = FlashcardSessionViewModel(
            flashcards: FlashcardsInteractor(expressions: expressions, cards: cards),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            fixCards: fixer(spy, expressions, cards), now: { [now] in now },
            studiedLanguage: { "English" }, nativeLanguage: { "Russian" })
        await vm.start()
        let first = try #require(vm.current)
        #expect(first.expression.example.isEmpty)

        vm.fixCurrent()                                            // the answer isn't shown yet
        try await Task.sleep(for: .milliseconds(50))
        #expect(spy.calls == 0)

        vm.reveal()
        let before = try await cards.all()
        vm.fixCurrent()
        try await wait { vm.cardFix?.status(for: card) == .updated }
        let shown = try #require(vm.current)
        #expect(shown.id == first.id && !shown.expression.example.isEmpty && !shown.expression.context.isEmpty)
        #expect(Set(try await cards.all()) == Set(before))         // the progress untouched
        #expect(vm.isRevealed)                                     // still the same card, still to rate

        vm.rate(.again)                                            // it comes back today…
        try await wait { vm.reviewedCount == 1 && vm.current != nil && !vm.isRevealed }
        let back = try #require(vm.current)
        #expect(back.expression.id == card.id && !back.expression.example.isEmpty)   // …with the fixed texts
        #expect(vm.cardFix?.status(for: back.expression) == nil)   // the status belonged to that showing
    }

    // MARK: In flashcards → the card view

    @MainActor @Test func fixingFromTheCardViewReplacesTheRow() async throws {
        let card = lacking()
        let expressions = MockExpressionRepository(seed: [card])
        let cards = MockReviewCardRepository(seed: newCards(card))
        let vm = StudyListViewModel(
            studyList: StudyListInteractor(repository: expressions, cards: cards),
            saveExpression: SaveExpressionInteractor(enrich: EnrichExpressionInteractor(llm: MockLLMClient()),
                                                     repository: expressions),
            exportAlgoApp: ExportDeckInteractor(repository: expressions, exporter: AlgoAppXMLExporter()),
            exportAnki: ExportDeckInteractor(repository: expressions, exporter: AnkiExporter()),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            isConfigured: true,
            flashcards: FlashcardsInteractor(expressions: expressions, cards: cards),
            fixCards: fixer(MockLLMClient(), expressions, cards),
            scope: .studying,
            studiedLanguage: { "English" }, nativeLanguage: { "Russian" })
        await vm.load()
        #expect(vm.expressions.map(\.id) == [card.id])

        vm.fixCard(card)
        #expect(vm.cardFix?.status(for: card) == .fixing)
        try await wait { vm.cardFix?.status(for: card) == .updated }
        let row = try #require(vm.expressions.first)
        #expect(!FixCardsInteractor.needsCompletion(row))
        #expect(vm.cards(for: row).count == 2)
    }
}

/// Answers like the mock, counting the requests.
private final class CountingFixLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        lock.withLock { count += 1 }
        return try await MockLLMClient().run(template, input: input)
    }
}

private struct FailingLLM: LLMClient {
    let error: LLMError
    init(_ error: LLMError) { self.error = error }
    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        throw error
    }
}

/// Answers the fix request — without the card that was asked about.
private struct ForgetfulLLM: LLMClient {
    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        guard let empty = FixCardsResult(cards: []) as? Template.Output else {
            return try await MockLLMClient().run(template, input: input)
        }
        return empty
    }
}
