//
//  FixCardsTests.swift
//  EnglishHelperTests
//
//  In flashcards → Fix cards: the prompt template, capital letters, the run in batches with progress,
//  resuming where it stopped (no card sent twice), unusable answers, the plan's limit, and what is
//  never touched (Caught phrases, learning progress).
//

import Testing
import Foundation
import Domain
import Adapters
import Presentation

@Suite struct FixCardsTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// `count` phrases in flashcards (lower-case, no example / synonyms / note), oldest first.
    private func deck(_ count: Int) -> ([Domain.Expression], [ReviewCard]) {
        let expressions = (0..<count).map {
            Domain.Expression(en: "phrase \($0)", ru: "фраза \($0)", createdAt: now.addingTimeInterval(Double($0)))
        }
        let cards = expressions.flatMap { e in
            CardDirection.allCases.map {
                ReviewCard(expressionID: e.id, direction: $0, state: .review, due: now, stability: 5, difficulty: 5,
                           reps: 4, lastReview: now.addingTimeInterval(-86_400))
            }
        }
        return (expressions, cards)
    }

    private func run(_ sut: FixCardsInteractor, restart: Bool = false, stopAfter: Int? = nil) async throws -> [FixProgress] {
        var steps: [FixProgress] = []
        for try await step in sut(studiedLanguage: "English", nativeLanguage: "Russian", restart: restart) {
            steps.append(step)
            if let stopAfter, step.processed >= stopAfter { break }
        }
        return steps
    }

    // MARK: Template

    @Test func templateRoundTripsTheCardsById() throws {
        let template = FixCardsTemplate(studiedLanguage: "German", nativeLanguage: "Russian")
        #expect(template.systemPrompt.contains("German"))
        #expect(template.systemPrompt.contains("\"der\"/\"die\"/\"das\""))
        #expect(template.modelTier == .fast)
        let message = template.userMessage(for: [FixCardItem(id: "42", expression: "tisch", translation: "стол",
                                                             example: "", synonyms: [], context: "")])
        #expect(message.contains("\"id\":\"42\""))
        let decoded = try template.decode(#"""
        {"cards":[
          {"id":"42","expression":" **der Tisch** ","translation":"стол","example":"Der Tisch ist neu.",
           "synonyms":["die Tafel","das Pult","der Schreibtisch","der Esstisch"],"context":"Нейтрально."},
          {"id":"7","expression":"","translation":"x","example":"","synonyms":[],"context":""}
        ]}
        """#)
        #expect(decoded.cards.map(\.id) == ["42"])                  // an empty expression is dropped
        #expect(decoded.cards[0].expression == "der Tisch")
        #expect(decoded.cards[0].synonyms.count == 3)
    }

    @Test func capitalLetters() {
        #expect(FixCardsInteractor.capitalized("to run") == "To run")
        #expect(FixCardsInteractor.capitalized("«привет»") == "«Привет»")
        #expect(FixCardsInteractor.capitalized("123 go") == "123 Go")
        #expect(FixCardsInteractor.capitalized("Already") == "Already")
        #expect(FixCardsInteractor.capitalized("") == "")
    }

    // MARK: Runs

    /// 45 phrases in batches of 20: progress after each batch; every card capitalised and completed;
    /// Caught phrases and the learning progress are left alone.
    @Test func goesThroughEveryPhraseInBatches() async throws {
        let (studied, cards) = deck(45)
        let caught = Domain.Expression(en: "caught one", ru: "пойманная")
        let expressions = MockExpressionRepository(seed: studied + [caught])
        let reviewCards = MockReviewCardRepository(seed: cards)
        let sut = FixCardsInteractor(llm: MockLLMClient(), expressions: expressions, cards: reviewCards)

        let steps = try await run(sut)
        #expect(steps.map(\.processed) == [0, 20, 40, 45])
        #expect(steps.last == FixProgress(processed: 45, total: 45, changed: 45, failed: 0))
        let fixed = try await expressions.all().filter { $0.id != caught.id }
        #expect(fixed.allSatisfy { $0.en.hasPrefix("Phrase") && $0.ru.hasPrefix("Фраза") })
        #expect(fixed.allSatisfy { !$0.example.isEmpty && !$0.synonyms.isEmpty && !$0.context.isEmpty })
        #expect(try await expressions.all().first { $0.id == caught.id }?.en == "caught one")
        #expect(Set(try await reviewCards.all()) == Set(cards))     // learning progress untouched
        let left0 = try await sut.remaining()
        #expect(left0.left == 0 && left0.total == 45)
    }

    /// Stopped after a batch (here: the connection drops on the second): the next run continues after
    /// it — no card is sent twice — and "start over" goes through all of them again.
    @Test func resumesWhereItStopped() async throws {
        let (studied, cards) = deck(45)
        let spy = SpyFixLLM(failing: [2: .offline])                       // the 2nd batch: no network
        let sut = FixCardsInteractor(llm: spy, expressions: MockExpressionRepository(seed: studied),
                                     cards: MockReviewCardRepository(seed: cards))
        await #expect(throws: LLMError.self) { _ = try await run(sut) }
        let afterStop = try await sut.remaining()
        #expect(afterStop.left == 25 && afterStop.total == 45)

        let rest = try await run(sut)
        #expect(rest.first?.total == 25)
        #expect(spy.answeredIDs.count == 45 && Set(spy.answeredIDs).count == 45)   // none twice

        let again = try await run(sut, restart: true)
        #expect(again.first?.total == 45)
    }

    /// An unusable answer (twice) skips the model's fix for that batch — capitals still applied — and
    /// the run goes on; the plan's limit stops it, keeping the position before the refused batch.
    @Test func badAnswersAndThePlanLimit() async throws {
        let (studied, cards) = deck(45)
        let expressions = MockExpressionRepository(seed: studied)
        let flaky = ScriptedFixLLM(script: [.failure(LLMError.invalidOutput("x")), .failure(LLMError.invalidOutput("x")),
                                           .success, .failure(LLMError.subscriptionRequired(retryAfter: nil))])
        let sut = FixCardsInteractor(llm: flaky, expressions: expressions, cards: MockReviewCardRepository(seed: cards))
        var steps: [FixProgress] = []
        var stoppedBy: Error?
        do {
            for try await step in sut(studiedLanguage: "English", nativeLanguage: "Russian", restart: false) {
                steps.append(step)
            }
        } catch { stoppedBy = error }

        #expect(steps.last == FixProgress(processed: 40, total: 45, changed: 40, failed: 20))
        guard case LLMError.subscriptionRequired? = stoppedBy as? LLMError else {
            Issue.record("the plan's limit should stop the run, got \(String(describing: stoppedBy))")
            return
        }
        let firstBatch = try await expressions.all().filter { $0.createdAt < now.addingTimeInterval(20) }
        #expect(firstBatch.allSatisfy { $0.en.hasPrefix("Phrase") && $0.example.isEmpty })  // capitals only
        let left5 = try await sut.remaining()
        #expect(left5.left == 5 && left5.total == 45)
    }
}

@Suite @MainActor struct FixCardsViewModelTests {
    @Test func runsToDoneAndTheListOffersIt() async throws {
        let expressions = MockExpressionRepository(seed: MockExpressionRepository.defaultSeed)
        let cards = MockReviewCardRepository()
        let flashcards = FlashcardsInteractor(expressions: expressions, cards: cards)
        for e in MockExpressionRepository.defaultSeed { try await flashcards.enroll(e.id, now: Date()) }
        let fix = FixCardsInteractor(llm: MockLLMClient(), expressions: expressions, cards: cards)
        let list = StudyListViewModel(
            studyList: StudyListInteractor(repository: expressions, cards: cards),
            saveExpression: SaveExpressionInteractor(enrich: EnrichExpressionInteractor(llm: MockLLMClient()),
                                                     repository: expressions),
            exportAlgoApp: ExportDeckInteractor(repository: expressions, exporter: AlgoAppXMLExporter()),
            exportAnki: ExportDeckInteractor(repository: expressions, exporter: AnkiExporter()),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            isConfigured: true, flashcards: flashcards, fixCards: fix, scope: .studying)
        #expect(list.canFixCards)
        list.prepareFix()
        var tries = 0
        while !list.showFixConfirmation, tries < 200 { tries += 1; try await Task.sleep(for: .milliseconds(10)) }
        #expect(list.fixRemaining?.left == 2 && list.fixRemaining?.total == 2)

        list.startFix(restart: false)
        let session = try #require(list.fixSession)
        tries = 0
        while session.isRunning, tries < 200 { tries += 1; try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.phase == .done)
        #expect(session.progress.processed == 2)
    }
}

/// Records the card ids it answered; answers like the mock (echo + fill), failing the calls listed.
private final class SpyFixLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    private var calls = 0
    private let failing: [Int: LLMError]
    init(failing: [Int: LLMError] = [:]) { self.failing = failing }
    var answeredIDs: [String] { lock.withLock { ids } }

    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        let call = lock.withLock { calls += 1; return calls }
        if let error = failing[call] { throw error }
        if let cards = input as? [FixCardItem] { lock.withLock { ids += cards.map(\.id) } }
        return try await MockLLMClient().run(template, input: input)
    }
}

/// Answers batch after batch from a script: like the mock, or an error.
private final class ScriptedFixLLM: LLMClient, @unchecked Sendable {
    enum Step { case success, failure(Error) }
    private let lock = NSLock()
    private var script: [Step]
    init(script: [Step]) { self.script = script }

    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        let step: Step = lock.withLock { script.isEmpty ? .success : script.removeFirst() }
        switch step {
        case .success: return try await MockLLMClient().run(template, input: input)
        case .failure(let error): throw error
        }
    }
}
