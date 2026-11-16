//
//  FixCardsTests.swift
//  EnglishHelperTests
//
//  In flashcards → Fix cards: the prompt template, letter case, the run in batches with progress,
//  resuming where it stopped (no answered card sent twice), only the incomplete cards (a checkpoint of
//  their own), a field the model leaves empty, phrases the model gave no answer for (an unusable
//  answer, a card left out — remembered, asked about alone by the next run, given up when even that
//  gets no answer), a service that doesn't answer (the run stops before that batch), nothing answering
//  at all (the run stops, nobody is given up), the plan's limit, and what is never touched (Caught
//  phrases, learning progress).
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

    // MARK: Completing phrases before they move from Caught

    /// Only the phrases that lack something go to the model — in requests of 20 — and are stored
    /// filled in; a complete one is returned as it is, with no request at all.
    @Test func completeFillsOnlyWhatLacks() async throws {
        let full = Domain.Expression(en: "jump the gun", ru: "поторопиться", example: "don't jump the gun.",
                                     synonyms: ["rush"], context: "разговорное.")
        let lacking = (0..<25).map { Domain.Expression(en: "phrase \($0)", ru: "фраза \($0)") }
        let expressions = MockExpressionRepository(seed: [full] + lacking)
        let spy = SpyFixLLM()
        let sut = FixCardsInteractor(llm: spy, expressions: expressions, cards: MockReviewCardRepository())

        let done = try await sut.complete([full] + lacking, studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(done.map(\.id) == ([full] + lacking).map(\.id))                     // all of them, in order
        #expect(done[0] == full)
        #expect(done.dropFirst().allSatisfy { !FixCardsInteractor.needsCompletion($0) })
        #expect(spy.answeredIDs.count == 25 && !spy.answeredIDs.contains(full.id.uuidString))
        #expect(try await expressions.all().filter(FixCardsInteractor.needsCompletion).isEmpty)   // stored

        let none = SpyFixLLM()
        let nothingToDo = FixCardsInteractor(llm: none, expressions: expressions, cards: MockReviewCardRepository())
        _ = try await nothingToDo.complete([full], studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(none.answeredIDs.isEmpty)
    }

    /// The model can't be reached / the plan's limit: it throws and stores nothing — the move stops.
    @Test func completeStopsOnTheLimit() async throws {
        let lacking = [Domain.Expression(en: "phrase", ru: "фраза")]
        let expressions = MockExpressionRepository(seed: lacking)
        let sut = FixCardsInteractor(llm: SpyFixLLM(failing: [1: .subscriptionRequired(retryAfter: 300)]),
                                     expressions: expressions, cards: MockReviewCardRepository())
        await #expect(throws: LLMError.self) {
            _ = try await sut.complete(lacking, studiedLanguage: "English", nativeLanguage: "Russian")
        }
        #expect(try await expressions.all() == lacking)
    }

    @MainActor
    private func caughtList(_ expressions: MockExpressionRepository, _ cards: MockReviewCardRepository,
                            llm: any LLMClient) -> StudyListViewModel {
        StudyListViewModel(
            studyList: StudyListInteractor(repository: expressions, cards: cards),
            saveExpression: SaveExpressionInteractor(enrich: EnrichExpressionInteractor(llm: MockLLMClient()),
                                                     repository: expressions),
            exportAlgoApp: ExportDeckInteractor(repository: expressions, exporter: AlgoAppXMLExporter()),
            exportAnki: ExportDeckInteractor(repository: expressions, exporter: AnkiExporter()),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            isConfigured: true,
            flashcards: FlashcardsInteractor(expressions: expressions, cards: cards),
            fixCards: FixCardsInteractor(llm: llm, expressions: expressions, cards: cards),
            scope: .caught,
            studiedLanguage: { "English" }, nativeLanguage: { "Russian" })
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Moving one phrase: it's completed, gets its cards, and only then leaves Caught.
    @MainActor @Test func movingAPhraseCompletesItFirst() async throws {
        let phrase = Domain.Expression(en: "phrase", ru: "фраза")
        let expressions = MockExpressionRepository(seed: [phrase])
        let cards = MockReviewCardRepository()
        let vm = caughtList(expressions, cards, llm: MockLLMClient())
        await vm.load()

        vm.moveToFlashcards(phrase)
        #expect(vm.expressions.map(\.id) == [phrase.id] && vm.isMoving(phrase))      // stays until moved
        try await wait { vm.expressions.isEmpty }
        #expect(vm.expressions.isEmpty && vm.actionError == nil)
        #expect(try await cards.all().count == 2)
        let stored = try #require(try await expressions.all().first)
        #expect(!FixCardsInteractor.needsCompletion(stored))
    }

    /// The plan's limit while completing: nothing moves, the phrase stays on Caught, the user is told.
    @MainActor @Test func theLimitStopsAMoveAndKeepsThePhrase() async throws {
        let phrase = Domain.Expression(en: "phrase", ru: "фраза")
        let expressions = MockExpressionRepository(seed: [phrase])
        let cards = MockReviewCardRepository()
        let vm = caughtList(expressions, cards, llm: SpyFixLLM(failing: [1: .subscriptionRequired(retryAfter: 300)]))
        await vm.load()

        vm.moveToFlashcards(phrase)
        try await wait { vm.actionError != nil }
        #expect(vm.actionError != nil && !vm.isMoving(phrase))
        #expect(vm.actionNeedsSubscription)                                          // the message offers "Subscribe"
        #expect(vm.expressions.map(\.id) == [phrase.id])
        #expect(try await cards.all().isEmpty)
        vm.clearActionError()
        #expect(vm.actionError == nil && !vm.actionNeedsSubscription)
    }

    /// Any other failure (here: no connection) is a plain message — no subscription offered.
    @MainActor @Test func anOfflineMoveOffersNoSubscription() async throws {
        let phrase = Domain.Expression(en: "phrase", ru: "фраза")
        let expressions = MockExpressionRepository(seed: [phrase])
        let vm = caughtList(expressions, MockReviewCardRepository(), llm: SpyFixLLM(failing: [1: .offline]))
        await vm.load()

        vm.moveToFlashcards(phrase)
        try await wait { vm.actionError != nil }
        #expect(vm.actionError != nil && !vm.actionNeedsSubscription)
        #expect(vm.expressions.map(\.id) == [phrase.id])
    }

    /// Move all: phrases leave the list one by one as they move; the limit on the second group stops
    /// it — the first group is in flashcards, the rest is still on Caught, and the message says so.
    @MainActor @Test func moveAllStopsAtTheLimitKeepingTheRest() async throws {
        let phrases = (0..<30).map {
            Domain.Expression(en: "phrase \($0)", ru: "фраза \($0)", createdAt: now.addingTimeInterval(Double($0)))
        }
        let expressions = MockExpressionRepository(seed: phrases)
        let cards = MockReviewCardRepository()
        let vm = caughtList(expressions, cards, llm: SpyFixLLM(failing: [2: .subscriptionRequired(retryAfter: 300)]))
        await vm.load()

        vm.moveAllToFlashcards()
        #expect(vm.bulkMove?.total == 30 && vm.expressions.count == 30)               // nothing gone yet
        try await wait { vm.bulkMove == nil }
        #expect(vm.actionError?.contains("20") == true)                              // "20 of 30 moved"
        #expect(vm.actionNeedsSubscription)
        #expect(Set(vm.expressions.map(\.id)) == Set(phrases.suffix(10).map(\.id)))  // the oldest 20 moved
        #expect(Set(try await cards.all().map(\.expressionID)) == Set(phrases.prefix(20).map(\.id)))
        #expect(vm.movingIDs.isEmpty)
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

    /// An unusable answer (twice) leaves that batch without the model's fix — capitals still applied —
    /// and the run goes on, remembering those phrases for the next run; the plan's limit stops it,
    /// keeping the position before the refused batch.
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
        let left = try await sut.remaining(.all)
        #expect(left.left == 25 && left.total == 45)                    // 5 not reached + 20 unanswered
    }

    /// Phrases a run went past without an answer are asked about ALONE by the next one, before
    /// anything else; then come the phrases it hadn't reached. The answered ones are never sent again.
    @Test func theNextRunAsksAboutTheUnansweredAlone() async throws {
        let (studied, cards) = deck(50)
        let expressions = MockExpressionRepository(seed: studied)
        let reviews = MockReviewCardRepository(seed: cards)
        let store = InMemoryCardFixProgressStore()
        let unusable = LLMError.invalidOutput("x")
        // Batch 1: unusable twice. Batch 2: answered. Batch 3: no network.
        let first = FixCardsInteractor(llm: ScriptedFixLLM(script: [.failure(unusable), .failure(unusable), .success,
                                                                    .failure(LLMError.offline)]),
                                       expressions: expressions, cards: reviews, progress: store)
        await #expect(throws: LLMError.self) { _ = try await run(first) }
        let mark = try #require(await store.load(.all))
        #expect(mark.id == studied[39].id)                              // past the first two batches
        #expect(mark.unanswered == Set(studied.prefix(20).map(\.id)))
        let left = try await first.remaining(.all)
        #expect(left.left == 30 && left.total == 50)
        let survey = try #require(try await lastSurvey(first))
        #expect(survey.all == FixCounts(left: 30, total: 50))

        let spy = SpyFixLLM()
        let second = FixCardsInteractor(llm: spy, expressions: expressions, cards: reviews, progress: store)
        let steps = try await run(second)
        #expect(steps.last == FixProgress(processed: 30, total: 30, changed: 30, failed: 0))
        #expect(spy.requestSizes == Array(repeating: 1, count: 20) + [10])   // each alone, then the batch
        #expect(spy.answeredIDs == (studied.prefix(20) + studied.suffix(10)).map(\.id.uuidString))
        #expect(try await expressions.all().allSatisfy { !FixCardsInteractor.isIncomplete($0) })
        let after = try #require(await store.load(.all))
        #expect(after.unanswered.isEmpty && after.givenUp.isEmpty && after.id == studied[49].id)
        let done = try await second.remaining(.all)
        #expect(done.left == 0 && done.total == 50)
    }

    /// A service that doesn't answer (a timeout, an overload, a server error — after one more try)
    /// STOPS the run with that error, the position before the batch: nothing is walked past unanswered.
    /// One hiccup the second try gets over isn't noticed.
    @Test func aServiceThatDoesntAnswerStopsTheRun() async throws {
        for failure in [LLMError.overloaded, .timedOut, .requestFailed("HTTP 500: x")] {
            let (studied, cards) = deck(45)
            let store = InMemoryCardFixProgressStore()
            let llm = ScriptedFixLLM(script: [.success, .failure(failure), .failure(failure)])
            let sut = FixCardsInteractor(llm: llm, expressions: MockExpressionRepository(seed: studied),
                                         cards: MockReviewCardRepository(seed: cards), progress: store)
            var steps: [FixProgress] = []
            var stoppedBy: Error?
            do {
                for try await step in sut(.all, studiedLanguage: "English", nativeLanguage: "Russian", restart: false) {
                    steps.append(step)
                }
            } catch { stoppedBy = error }
            #expect(stoppedBy as? LLMError == failure)
            #expect(steps.last == FixProgress(processed: 20, total: 45, changed: 20, failed: 0, sent: 40))
            #expect(llm.calls == 3)                                     // no third batch through a dead service
            let mark = await store.load(.all)
            #expect(mark?.id == studied[19].id && mark?.unanswered.isEmpty == true)
            let left = try await sut.remaining(.all)
            #expect(left.left == 25 && left.total == 45)                // the refused batch goes again
        }

        let (studied, cards) = deck(45)
        let sut = FixCardsInteractor(llm: ScriptedFixLLM(script: [.failure(LLMError.overloaded)]),
                                     expressions: MockExpressionRepository(seed: studied),
                                     cards: MockReviewCardRepository(seed: cards))
        #expect(try await run(sut).last == FixProgress(processed: 45, total: 45, changed: 45, failed: 0))
    }

    /// A good answer that leaves cards out: they're counted and remembered. Asked about alone to no
    /// answer — with nothing else in the run to show that the model answers at all — they wait one
    /// more run; unanswered alone twice, they're GIVEN UP: not left to do, not sent again, until
    /// "start over".
    @Test func aCardTheModelNeverAnswersForIsGivenUp() async throws {
        let (studied, cards) = deck(40)
        let expressions = MockExpressionRepository(seed: studied)
        let reviews = MockReviewCardRepository(seed: cards)
        let store = InMemoryCardFixProgressStore()
        let leftOut = [studied[3], studied[25]], ids = Set(leftOut.map(\.id))
        let forgetful = ForgetfulFixLLM(forgetting: ids)
        let sut = FixCardsInteractor(llm: forgetful, expressions: expressions, cards: reviews, progress: store)

        let steps = try await run(sut)
        #expect(steps.last == FixProgress(processed: 40, total: 40, changed: 38, failed: 2))
        #expect(await store.load(.all)?.unanswered == ids)
        let left = try await sut.remaining(.all)
        #expect(left.left == 2 && left.total == 40)

        let again = try await run(sut)                                  // alone, once: still waiting
        #expect(again.last == FixProgress(processed: 2, total: 2, changed: 0, failed: 2))
        #expect(Array(forgetful.requests.suffix(2)) == leftOut.map { [$0.id.uuidString] })
        let waiting = try #require(await store.load(.all))
        #expect(waiting.unanswered == ids && waiting.askedAlone == ids && waiting.givenUp.isEmpty)

        let third = try await run(sut)                                  // alone, twice: given up
        #expect(third.last == FixProgress(processed: 2, total: 2, changed: 0, failed: 0, givenUp: 2))
        let given = try #require(await store.load(.all))
        #expect(given.unanswered.isEmpty && given.askedAlone.isEmpty && given.givenUp == ids)
        let done = try await sut.remaining(.all)
        #expect(done.left == 0 && done.total == 40)
        let asked = forgetful.requests.count
        #expect(try await run(sut).last == FixProgress(processed: 0, total: 0, changed: 0, failed: 0))
        #expect(forgetful.requests.count == asked)                      // not sent again

        let spy = SpyFixLLM()                                           // "start over": all of them again
        let fresh = FixCardsInteractor(llm: spy, expressions: expressions, cards: reviews, progress: store)
        #expect(try await run(fresh, restart: true).last == FixProgress(processed: 40, total: 40, changed: 2, failed: 0))
        #expect(await store.load(.all)?.givenUp.isEmpty == true)
        #expect(try await expressions.all().allSatisfy { !FixCardsInteractor.isIncomplete($0) })
    }

    /// The same run answers for other phrases — so the model works, and a phrase with no answer even
    /// alone is given up at once. Until a run has seen an answer, phrases asked alone wait behind the
    /// batches (three in a row unanswered could be the model's trouble, not theirs). A phrase deleted
    /// since isn't waited for.
    @Test func withAnAnswerInTheRunAPhraseIsGivenUpAtOnce() async throws {
        let (studied, cards) = deck(60)
        let expressions = MockExpressionRepository(seed: studied)
        let reviews = MockReviewCardRepository(seed: cards)
        let store = InMemoryCardFixProgressStore()
        let leftOut = [studied[3], studied[7], studied[25], studied[30], studied[31]]
        // Two batches answered (without those five), then no network.
        let first = FixCardsInteractor(llm: ForgetfulFixLLM(forgetting: Set(leftOut.map(\.id)), offlineFrom: 3),
                                       expressions: expressions, cards: reviews, progress: store)
        await #expect(throws: LLMError.self) { _ = try await run(first) }
        #expect(await store.load(.all)?.unanswered == Set(leftOut.map(\.id)))
        try await expressions.delete(id: leftOut[4].id)

        // Still forgetting three of the four that are left; the fourth is answered now.
        let forgetful = ForgetfulFixLLM(forgetting: Set(leftOut.prefix(3).map(\.id)))
        let second = FixCardsInteractor(llm: forgetful, expressions: expressions, cards: reviews, progress: store)
        let steps = try await run(second)
        #expect(steps.last == FixProgress(processed: 24, total: 24, changed: 21, failed: 0, givenUp: 3))
        // Three alone to no answer → the batch first (it answers) → the fourth alone.
        #expect(forgetful.requests.map(\.count) == [1, 1, 1, 20, 1])
        #expect(forgetful.requests.last == [leftOut[3].id.uuidString])
        let after = try #require(await store.load(.all))
        #expect(after.unanswered.isEmpty && after.givenUp == Set(leftOut.prefix(3).map(\.id)))
        let left = try await second.remaining(.all)
        #expect(left.left == 0 && left.total == 59)
    }

    /// Nothing answers at all — every request refused, or every answer unusable: three requests in a
    /// row without one answer stop the run with that error. The phrases it went past are remembered,
    /// NOBODY is given up, and once the model answers again they all get done.
    @Test func whenNothingAnswersTheRunStops() async throws {
        for failure in [LLMError.requestRejected("HTTP 400: x"), .invalidOutput("x")] {
            let (studied, cards) = deck(100)
            let expressions = MockExpressionRepository(seed: studied)
            let reviews = MockReviewCardRepository(seed: cards)
            let store = InMemoryCardFixProgressStore()
            let dead = ScriptedFixLLM(always: failure)
            let sut = FixCardsInteractor(llm: dead, expressions: expressions, cards: reviews, progress: store)
            var steps: [FixProgress] = []
            var stoppedBy: Error?
            do {
                for try await step in sut(.all, studiedLanguage: "English", nativeLanguage: "Russian", restart: false) {
                    steps.append(step)
                }
            } catch { stoppedBy = error }
            #expect(stoppedBy as? LLMError == failure)
            #expect(steps.last == FixProgress(processed: 60, total: 100, changed: 0, failed: 60))
            // A refused request isn't sent again as it is; an unusable answer is asked for once more.
            #expect(dead.calls == (failure == .invalidOutput("x") ? 6 : 3))
            let left = try await sut.remaining(.all)
            #expect(left.left == 100 && left.total == 100)              // 40 not reached + 60 unanswered

            // Still dead: three alone, one batch — and it stops again, giving nobody up.
            let before = dead.calls
            await #expect(throws: LLMError.self) { _ = try await run(sut) }
            #expect(dead.calls - before == (failure == .invalidOutput("x") ? 8 : 4))
            let mark = try #require(await store.load(.all))
            #expect(mark.givenUp.isEmpty && mark.unanswered.count == 80 && mark.askedAlone.count == 3)

            let alive = FixCardsInteractor(llm: SpyFixLLM(), expressions: expressions, cards: reviews, progress: store)
            #expect(try await run(alive).last == FixProgress(processed: 100, total: 100, changed: 100, failed: 0))
            #expect(await store.load(.all)?.givenUp.isEmpty == true)
            #expect(try await expressions.all().allSatisfy { !FixCardsInteractor.isIncomplete($0) })
        }
    }

    /// Caught → flashcards: a phrase the answer left out is asked about once more; still without an
    /// answer, the move stops — it never goes into flashcards unseen — and what was answered is kept.
    @Test func completingAsksAgainAboutWhatTheAnswerLeftOut() async throws {
        let lacking = (0..<4).map { Domain.Expression(en: "caught \($0)", ru: "пойманная \($0)", createdAt: now.addingTimeInterval(Double($0))) }
        let once = ForgetfulFixLLM(forgetting: [lacking[2].id], inTheFirst: 1)
        let expressions = MockExpressionRepository(seed: lacking)
        let completed = try await FixCardsInteractor(llm: once, expressions: expressions, cards: MockReviewCardRepository())
            .complete(lacking, studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(completed.map(\.id) == lacking.map(\.id))
        #expect(completed.allSatisfy { !FixCardsInteractor.needsCompletion($0) })
        #expect(once.requests == [lacking.map(\.id.uuidString), [lacking[2].id.uuidString]])

        let always = ForgetfulFixLLM(forgetting: [lacking[2].id])
        let store = MockExpressionRepository(seed: lacking)
        await #expect(throws: LLMError.self) {
            _ = try await FixCardsInteractor(llm: always, expressions: store, cards: MockReviewCardRepository())
                .complete(lacking, studiedLanguage: "English", nativeLanguage: "Russian")
        }
        #expect(always.requests.count == 2)
        let stored = try await store.all()
        #expect(stored.filter(FixCardsInteractor.needsCompletion).map(\.id) == [lacking[2].id])
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

        // The phrases left unanswered are stored with the position; a checkpoint from a build that
        // had none reads as "none".
        let asked = UUID()
        let waiting = CardFixCheckpoint(createdAt: now, id: UUID(), unanswered: [asked, UUID()], askedAlone: [asked],
                                        givenUp: [UUID()])
        await store.save(waiting, for: .incomplete)
        #expect(await store.load(.incomplete) == waiting)
        let old = #"{"createdAt":800000000,"id":"\#(a.id.uuidString)"}"#
        defaults.set(Data(old.utf8), forKey: "flashcardsFixCheckpoint")
        #expect(await store.load(.all) == CardFixCheckpoint(createdAt: now, id: a.id))
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
    private var sizes: [Int] = []
    private var calls = 0
    private let failing: [Int: LLMError]
    init(failing: [Int: LLMError] = [:]) { self.failing = failing }
    var answeredIDs: [String] { lock.withLock { ids } }
    /// How many cards each answered request carried.
    var requestSizes: [Int] { lock.withLock { sizes } }

    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        let call = lock.withLock { calls += 1; return calls }
        if let error = failing[call] { throw error }
        if let cards = input as? [FixCardItem] { lock.withLock { ids += cards.map(\.id); sizes.append(cards.count) } }
        return try await MockLLMClient().run(template, input: input)
    }
}

/// Answers like the mock but leaves the listed cards out of its answer — in its first `calls`
/// answers only, when given. Records what each request asked about.
private final class ForgetfulFixLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [[String]] = []
    private let forgetting: Set<String>
    private let forgetfulCalls: Int
    private let offlineFrom: Int
    /// `offlineFrom`: the call from which there's no network.
    init(forgetting: Set<UUID>, inTheFirst calls: Int = .max, offlineFrom: Int = .max) {
        self.forgetting = Set(forgetting.map(\.uuidString))
        self.forgetfulCalls = calls
        self.offlineFrom = offlineFrom
    }
    var requests: [[String]] { lock.withLock { asked } }

    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        let ids = (input as? [FixCardItem] ?? []).map(\.id)
        let call = lock.withLock { asked.append(ids); return asked.count }
        if call >= offlineFrom { throw LLMError.offline }
        let answer = try await MockLLMClient().run(template, input: input)
        guard call <= forgetfulCalls, let full = answer as? FixCardsResult,
              let cut = FixCardsResult(cards: full.cards.filter { !forgetting.contains($0.id) }) as? Template.Output
        else { return answer }
        return cut
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
    private var count = 0
    private var always: Error?
    init(script: [Step]) { self.script = script }
    /// Every call fails this way.
    init(always error: Error) {
        self.script = []
        self.always = error
    }
    var calls: Int { lock.withLock { count } }

    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        let step: Step = lock.withLock {
            count += 1
            if let always { return .failure(always) }
            return script.isEmpty ? .success : script.removeFirst()
        }
        switch step {
        case .success: return try await MockLLMClient().run(template, input: input)
        case .failure(let error): throw error
        }
    }
}
