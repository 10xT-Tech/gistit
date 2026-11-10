//
//  FixCardsTests.swift
//  EnglishHelperTests
//
//  In flashcards → Fix cards: the prompt template, letter case, the run in batches with progress,
//  resuming where it stopped (no card sent twice), only the incomplete cards (a checkpoint of their
//  own), a field the model leaves empty, unusable answers, the plan's limit, and what is never touched
//  (Caught phrases, learning progress).
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

    private func run(_ sut: FixCardsInteractor, _ scope: FixScope = .all, restart: Bool = false,
                     stopAfter: Int? = nil) async throws -> [FixProgress] {
        var steps: [FixProgress] = []
        for try await step in sut(scope, studiedLanguage: "English", nativeLanguage: "Russian", restart: restart) {
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
        #expect(template.modelTier == .standard)                    // the explanation model
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

    /// Lower case everywhere — but the English "I", and German nouns left alone.
    @Test func letterCase() {
        let en = { FixCardsInteractor.lettercase($0, language: "English") }
        #expect(en("A Corkscrew") == "a corkscrew")
        #expect(en("To Abandon") == "to abandon")
        #expect(en("I appreciate it") == "I appreciate it")
        #expect(en("i'm tired, i think") == "I'm tired, I think")
        #expect(en("I’ve Been There") == "I’ve been there")
        #expect(en("Is it in? Hi!") == "is it in? hi!")                 // other "i"s untouched
        #expect(FixCardsInteractor.lettercase("Я Ценю Это", language: "Russian") == "я ценю это")
        #expect(FixCardsInteractor.lettercase("I Ragazzi", language: "Italian") == "i ragazzi")   // an article
        #expect(FixCardsInteractor.lettercase("der Tisch", language: "German") == "der Tisch")
        #expect(en("") == "")
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
        // Sent to the model first (grey), answered after (green): the second catches up with the first.
        #expect(steps.map { [$0.sent, $0.processed] } == [[0, 0], [20, 0], [20, 20], [40, 20], [40, 40], [45, 40], [45, 45]])
        #expect(steps.last == FixProgress(processed: 45, total: 45, changed: 45, failed: 0))
        let fixed = try await expressions.all().filter { $0.id != caught.id }
        #expect(fixed.allSatisfy { $0.en.hasPrefix("phrase") && $0.ru.hasPrefix("фраза") })
        #expect(fixed.allSatisfy { $0.example == $0.example.lowercased() })
        #expect(fixed.allSatisfy { !$0.example.isEmpty && !$0.synonyms.isEmpty && !$0.context.isEmpty })
        #expect(try await expressions.all().first { $0.id == caught.id }?.en == "caught one")
        #expect(Set(try await reviewCards.all()) == Set(cards))     // learning progress untouched
        let left0 = try await sut.remaining(.all)
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
        let afterStop = try await sut.remaining(.all)
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
            for try await step in sut(.all, studiedLanguage: "English", nativeLanguage: "Russian", restart: false) {
                steps.append(step)
            }
        } catch { stoppedBy = error }

        // The first batch was already lower case: only the second changed; the refused batch was sent,
        // never answered.
        #expect(steps.last == FixProgress(processed: 40, total: 45, changed: 20, failed: 20, sent: 45))
        guard case LLMError.subscriptionRequired? = stoppedBy as? LLMError else {
            Issue.record("the plan's limit should stop the run, got \(String(describing: stoppedBy))")
            return
        }
        let firstBatch = try await expressions.all().filter { $0.createdAt < now.addingTimeInterval(20) }
        #expect(firstBatch.allSatisfy { $0.en.hasPrefix("phrase") && $0.example.isEmpty })  // letter case only
        let left5 = try await sut.remaining(.all)
        #expect(left5.left == 5 && left5.total == 45)
    }

    /// "Only incomplete": just the cards missing an example, synonyms or a note go to the model; the
    /// run keeps its own position — stopping it leaves the all-cards run where it was.
    @Test func onlyTheIncompleteCards() async throws {
        let (studied, cards) = deck(50)
        let complete = studied.enumerated().map { index, expression in
            var e = expression
            e.example = "an example."
            e.synonyms = ["a synonym"]
            e.context = "заметка."
            switch index % 5 {                                   // 30 of 50 miss one of the three
            case 0: e.example = ""
            case 1: e.synonyms = []
            case 2: e.context = ""
            default: break
            }
            return e
        }
        let expressions = MockExpressionRepository(seed: complete)
        let spy = SpyFixLLM(failing: [2: .offline])                       // the 2nd batch: no network
        let sut = FixCardsInteractor(llm: spy, expressions: expressions, cards: MockReviewCardRepository(seed: cards))
        let incomplete = try await sut.remaining(.incomplete)
        #expect(incomplete.left == 30 && incomplete.total == 30)

        await #expect(throws: LLMError.self) { _ = try await run(sut, .incomplete) }
        let afterStop = try await sut.remaining(.incomplete)
        #expect(afterStop.left == 10 && afterStop.total == 10)          // the first 20 are complete now
        let all = try await sut.remaining(.all)
        #expect(all.left == 50 && all.total == 50)                      // its own position, untouched
        let survey = try #require(try await lastSurvey(sut))
        #expect(survey.all == FixCounts(left: 50, total: 50) && survey.incomplete == FixCounts(left: 10, total: 10))

        let rest = try await run(sut, .incomplete)
        #expect(rest.last == FixProgress(processed: 10, total: 10, changed: 10, failed: 0))
        let sent = Set(spy.answeredIDs)
        #expect(spy.answeredIDs.count == 30 && sent.count == 30)        // none twice
        #expect(sent == Set(complete.filter(FixCardsInteractor.isIncomplete).map(\.id.uuidString)))
        #expect(try await expressions.all().allSatisfy { !FixCardsInteractor.isIncomplete($0) })
        let done = try await sut.remaining(.incomplete)
        #expect(done.left == 0 && done.total == 0)
    }

    /// Reading before a run: progress over every phrase, then what each mode covers.
    @Test func surveyCountsWithProgress() async throws {
        let (studied, cards) = deck(450)
        let caught = Domain.Expression(en: "caught one", ru: "пойманная")
        let sut = FixCardsInteractor(llm: SpyFixLLM(failing: [2: .offline]),             // one batch, then offline
                                     expressions: MockExpressionRepository(seed: studied + [caught]),
                                     cards: MockReviewCardRepository(seed: cards))
        var steps: [FixSurvey] = []
        for try await step in sut.survey() { steps.append(step) }
        #expect(steps.map(\.checked) == [0] + Array(stride(from: 50, through: 450, by: 50)))
        #expect(steps.last?.all == FixCounts(left: 450, total: 450))
        #expect(steps.last?.incomplete == FixCounts(left: 450, total: 450))       // the deck has no examples
        #expect(steps.dropLast().allSatisfy { $0.all == nil })

        await #expect(throws: LLMError.self) { _ = try await run(sut) }
        let after = try #require(try await lastSurvey(sut))
        #expect(after.all == FixCounts(left: 430, total: 450))
        #expect(after.incomplete == FixCounts(left: 430, total: 430))            // 20 are complete now
    }

    private func lastSurvey(_ sut: FixCardsInteractor) async throws -> FixSurvey? {
        var last: FixSurvey?
        for try await step in sut.survey() { last = step }
        return last
    }

    /// A field the model returns empty keeps what the card had; filled ones replace it.
    @Test func anEmptyAnswerNeverEmptiesAField() async throws {
        let (studied, cards) = deck(2)
        var filled = studied[0]
        filled.example = "keep this example."
        filled.synonyms = ["keep", "these"]
        filled.context = "оставить."
        let expressions = MockExpressionRepository(seed: [filled, studied[1]])
        let sut = FixCardsInteractor(llm: EmptyingFixLLM(), expressions: expressions,
                                     cards: MockReviewCardRepository(seed: cards))
        _ = try await run(sut)
        let after = try await expressions.all()
        let kept = try #require(after.first { $0.id == filled.id })
        #expect(kept.example == "keep this example." && kept.synonyms == ["keep", "these"] && kept.context == "оставить.")
        #expect(kept.en == "phrase 0 fixed")                            // the rest of the answer applies
        let empty = try #require(after.first { $0.id == studied[1].id })
        #expect(empty.example.isEmpty && empty.synonyms.isEmpty && empty.context.isEmpty)
    }

    /// Each scope's position is a value of its own; the all-cards one keeps the key it always had.
    @Test func checkpointsPerScope() async throws {
        let defaults = try #require(UserDefaults(suiteName: "fix-\(UUID().uuidString)"))
        let store = UserDefaultsCardFixProgressStore(defaults: defaults)
        let a = CardFixCheckpoint(createdAt: now, id: UUID()), b = CardFixCheckpoint(createdAt: now, id: UUID())
        await store.save(a, for: .all)
        await store.save(b, for: .incomplete)
        let all = await store.load(.all), incomplete = await store.load(.incomplete)
        #expect(all == a && incomplete == b)
        #expect(defaults.data(forKey: "flashcardsFixCheckpoint") != nil)
        await store.reset(.incomplete)
        let allAfter = await store.load(.all), incompleteAfter = await store.load(.incomplete)
        #expect(allAfter == a && incompleteAfter == nil)
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
        list.openFix()
        let session = try #require(list.fixSession)
        #expect(session.phase == .surveying)
        session.prepare()                                               // the sheet does it on appear
        var tries = 0
        while session.phase == .surveying, tries < 200 { tries += 1; try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.phase == .choosing)
        #expect(session.all == FixCounts(left: 2, total: 2))
        #expect(session.incomplete == FixCounts(left: 0, total: 0))    // the seed cards are complete

        session.run(.all, restart: false)
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

/// Fixes the expression but returns every other field empty.
private struct EmptyingFixLLM: LLMClient {
    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        let cards = (input as? [FixCardItem] ?? []).map {
            FixCardItem(id: $0.id, expression: $0.expression + " fixed", translation: $0.translation,
                        example: "", synonyms: [], context: "")
        }
        return try template.decode(String(decoding: try JSONEncoder().encode(FixCardsResult(cards: cards)), as: UTF8.self))
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
