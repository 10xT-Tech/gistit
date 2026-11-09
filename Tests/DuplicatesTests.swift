//
//  DuplicatesTests.swift
//  EnglishHelperTests
//
//  Duplicates: the comparison key (articles, "to", placeholders, punctuation, word forms), the scan
//  over flashcards (Caught left out, "not duplicates" hidden, progress), the model's check in batches
//  (sent / answered, unusable answers, a stop that keeps the verdicts), the merge (texts, which card
//  each direction keeps, a caught phrase merged into its flashcard), the template, and the screens:
//  a look-alike moved from Caught, Move all without look-alikes, the Find duplicates sheet.
//

import Testing
import Foundation
import Domain
import Adapters
import Presentation

@Suite struct DuplicatesTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func phrase(_ en: String, _ ru: String, _ minute: Double, example: String = "") -> Domain.Expression {
        Domain.Expression(en: en, ru: ru, example: example, createdAt: now.addingTimeInterval(minute * 60))
    }

    /// Both directions: recognition in review with `stability`, recall `recall` (new by default).
    private func cards(_ e: Domain.Expression, stability: Double = 5, recall: ReviewState = .new,
                       recallStability: Double = 0) -> [ReviewCard] {
        [ReviewCard(expressionID: e.id, direction: .recognition, state: .review, due: now, stability: stability,
                    difficulty: 5, reps: 3, lastReview: now.addingTimeInterval(-86_400)),
         ReviewCard(expressionID: e.id, direction: .recall, state: recall, due: now, stability: recallStability,
                    difficulty: recall == .new ? 0 : 5, reps: recall == .new ? 0 : 1,
                    lastReview: recall == .new ? nil : now.addingTimeInterval(-600))]
    }

    // MARK: Key

    @Test func phraseKey() {
        let en = { PhraseKey.make($0, language: "English") }
        #expect(en("to hit the roof") == "hit the roof")
        #expect(en("Hit the roof!") == "hit the roof")
        #expect(en("pick on") == en("to pick on someone"))
        #expect(en("wind (someone) up") == en("wind sb up"))
        #expect(en("the more…, the more…") == en("the more ... the more"))
        #expect(en("A Corkscrew") == en("corkscrew"))
        #expect(en("finish + -ing") == en("to finish"))
        #expect(en("I’m off") == en("i'm off"))
        #expect(en("hit the road") != en("hit the roof"))
        #expect(en("something") == "something")                      // a placeholder alone stays
        #expect(PhraseKey.make("der Tisch", language: "German") == PhraseKey.make("Tisch", language: "German"))
        #expect(PhraseKey.make("l'Arbre", language: "French") == PhraseKey.make("arbre", language: "French"))
        #expect(PhraseKey.make("faire quelque chose", language: "French") == "faire")
        #expect(PhraseKey.make("café", language: "French") == "cafe")
    }

    @Test func wordFormsWithALemmatizer() async {
        struct Lemmas: Lemmatizing {
            func prepare(language: String) async {}
            func lemmatize(_ text: String, language: String) -> String {
                text.split(separator: " ").map { ["jumping": "jump", "jumped": "jump"][String($0)] ?? String($0) }
                    .joined(separator: " ")
            }
        }
        #expect(PhraseKey.make("Jumping the gun", language: "English", lemmatizer: Lemmas())
                == PhraseKey.make("to jump the gun", language: "English", lemmatizer: Lemmas()))
        let natural = NaturalLanguageLemmatizer()
        await natural.prepare(language: "English")
        #expect(natural.lemmatize("jumping the gun", language: "English") == "jump the gun")
    }

    // MARK: Scan

    @Test func scanGroupsLookAlikesInFlashcards() async throws {
        let roof1 = phrase("hit the roof", "взбеситься", 0), roof2 = phrase("to hit the roof", "взбеситься", 1)
        let solid1 = phrase("solid", "надёжный", 2), solid2 = phrase("solid", "твёрдый", 3)
        let unique = phrase("jump the gun", "поторопиться", 4)
        let caught = phrase("Hit the roof!", "разозлиться", 5)                          // no cards
        let studied = [roof1, roof2, solid1, solid2, unique]
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: MockExpressionRepository(seed: studied + [caught]),
                                       cards: MockReviewCardRepository(seed: studied.flatMap { cards($0) }))

        let groups = try #require(try await scan(sut))
        #expect(groups.map { $0.expressions.map(\.id) } == [[roof1.id, roof2.id], [solid1.id, solid2.id]])
        #expect(groups[0].cards[roof1.id]?.count == 2)

        let alike = try await sut.lookAlikesInFlashcards(for: [caught, unique], studiedLanguage: "English")
        #expect(alike[caught.id]?.map(\.id) == [roof1.id, roof2.id])
        #expect(alike[unique.id] == nil)                                             // only itself

        await sut.dismiss(groups[1])                                                 // "not duplicates"
        #expect(try await scan(sut)?.map(\.key) == ["hit the roof"])
    }

    @Test func scanReportsProgress() async throws {
        let studied = (0..<450).map { phrase("phrase \($0)", "фраза", Double($0)) }
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: MockExpressionRepository(seed: studied),
                                       cards: MockReviewCardRepository(seed: studied.flatMap { cards($0) }))
        var steps: [DuplicateScanStep] = []
        for try await step in sut.scan(studiedLanguage: "English") { steps.append(step) }
        #expect(steps.map(\.checked) == [0, 200, 400, 450])
        #expect(steps.last?.groups == [])
    }

    private func scan(_ sut: DuplicatesInteractor) async throws -> [DuplicateGroup]? {
        var groups: [DuplicateGroup]?
        for try await step in sut.scan(studiedLanguage: "English") { groups = step.groups ?? groups }
        return groups
    }

    // MARK: Check

    /// Twelve groups (half the same meaning twice, half different meanings) in batches of ten.
    private func twelveGroups() -> ([Domain.Expression], [ReviewCard]) {
        let studied = (0..<12).flatMap { n in
            [phrase("phrase \(n)", "фраза \(n)", Double(n * 2)),
             phrase("to phrase \(n)", n.isMultiple(of: 2) ? "фраза \(n)" : "другая \(n)", Double(n * 2 + 1))]
        }
        return (studied, studied.flatMap { cards($0) })
    }

    @Test func checkSendsBatchesAndCollectsVerdicts() async throws {
        let (studied, reviewCards) = twelveGroups()
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: MockExpressionRepository(seed: studied),
                                       cards: MockReviewCardRepository(seed: reviewCards))
        let groups = try #require(try await scan(sut))
        #expect(groups.count == 12)
        var steps: [DuplicateCheckStep] = []
        for try await step in sut.check(groups, studiedLanguage: "English", nativeLanguage: "Russian") { steps.append(step) }
        #expect(steps.map { [$0.sent, $0.answered] } == [[0, 0], [10, 0], [10, 10], [12, 10], [12, 12]])
        let verdicts = steps.reduce(into: [String: DuplicateVerdict]()) { $0.merge($1.verdicts) { _, new in new } }
        #expect(verdicts.count == 12)
        let first = try #require(verdicts[groups[0].id]), second = try #require(verdicts[groups[1].id])
        #expect(first.verdict == .duplicate && first.card.translation == "фраза 0")
        #expect(second.verdict == .senses && second.card.translation == "1) фраза 1 2) другая 1")
    }

    /// An unusable answer (twice) leaves its batch unchecked and the check goes on; going offline stops
    /// it.
    @Test func unusableAnswersAndAStop() async throws {
        let (studied, reviewCards) = twelveGroups()
        let llm = ScriptedLLM(script: [.failure(LLMError.invalidOutput("x")), .failure(LLMError.invalidOutput("x"))])
        let sut = DuplicatesInteractor(llm: llm, expressions: MockExpressionRepository(seed: studied),
                                       cards: MockReviewCardRepository(seed: reviewCards))
        let groups = try #require(try await scan(sut))
        var steps: [DuplicateCheckStep] = []
        for try await step in sut.check(groups, studiedLanguage: "English", nativeLanguage: "Russian") { steps.append(step) }
        #expect(steps.last?.failed == 10)                                            // the first batch
        #expect(steps.last?.answered == 12)
        #expect(steps.flatMap { $0.verdicts.keys }.count == 2)                       // the second batch

        let offline = DuplicatesInteractor(llm: ScriptedLLM(script: [.failure(LLMError.offline)]),
                                           expressions: MockExpressionRepository(seed: studied),
                                           cards: MockReviewCardRepository(seed: reviewCards))
        await #expect(throws: LLMError.self) {
            for try await _ in offline.check(groups, studiedLanguage: "English", nativeLanguage: "Russian") {}
        }
    }

    // MARK: Merge

    private let merged = CardText(expression: "To Hit The Roof", translation: "Взбеситься / разозлиться",
                                  example: "", synonyms: ["go mad"], context: "Разговорное.")

    /// One meaning twice: the oldest phrase stays with the merged texts; each direction keeps the
    /// best-known card (its id too, so today's answers still count); the other phrase goes.
    @Test func mergingADuplicateKeepsTheBestProgress() async throws {
        let a = phrase("hit the roof", "взбеситься", 0, example: "dad hit the roof.")
        let b = phrase("to hit the roof", "разозлиться", 1)
        let aCards = cards(a, stability: 3), bCards = cards(b, stability: 30, recall: .learning, recallStability: 1)
        let expressions = MockExpressionRepository(seed: [a, b])
        let reviewCards = MockReviewCardRepository(seed: aCards + bCards)
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions, cards: reviewCards)

        try await sut.merge([a, b], into: merged, as: .duplicate, studiedLanguage: "English", nativeLanguage: "Russian")
        let left = try await expressions.all()
        #expect(left.map(\.id) == [a.id])
        #expect(left[0].en == "to hit the roof" && left[0].ru == "взбеситься / разозлиться")
        #expect(left[0].example == "dad hit the roof.")                              // the model left it empty
        #expect(left[0].synonyms == ["go mad"] && left[0].context == "разговорное.")
        let kept = try await reviewCards.all()
        #expect(kept.count == 2 && kept.allSatisfy { $0.expressionID == a.id })
        let recognition = try #require(kept.first { $0.direction == .recognition })
        #expect(recognition.id == bCards[0].id && recognition.stability == 30)
        #expect(kept.first { $0.direction == .recall }?.id == bCards[1].id)          // the only one answered
    }

    /// Several meanings: each direction keeps the least-known answered card — it now asks for them all.
    @Test func mergingSensesKeepsTheLeastKnown() async throws {
        let a = phrase("solid", "надёжный", 0), b = phrase("solid", "твёрдый", 1)
        let aCards = cards(a, stability: 3), bCards = cards(b, stability: 30, recall: .learning, recallStability: 1)
        let reviewCards = MockReviewCardRepository(seed: aCards + bCards)
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: MockExpressionRepository(seed: [a, b]),
                                       cards: reviewCards)
        try await sut.merge([a, b], into: merged, as: .senses, studiedLanguage: "English", nativeLanguage: "Russian")
        let kept = try await reviewCards.all()
        #expect(kept.first { $0.direction == .recognition }?.id == aCards[0].id)
        #expect(kept.first { $0.direction == .recall }?.id == bCards[1].id)
    }

    /// A caught phrase (no cards) merged into its look-alike in flashcards: the flashcard stays, even
    /// when the caught one is older.
    @Test func mergingACaughtPhraseKeepsTheFlashcard() async throws {
        let caught = phrase("Hit the roof!", "разозлиться", 0)
        let studied = phrase("hit the roof", "взбеситься", 5)
        let expressions = MockExpressionRepository(seed: [caught, studied])
        let studiedCards = cards(studied)
        let reviewCards = MockReviewCardRepository(seed: studiedCards)
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions, cards: reviewCards)
        try await sut.merge([studied, caught], into: merged, as: .duplicate, studiedLanguage: "English",
                            nativeLanguage: "Russian")
        #expect(try await expressions.all().map(\.id) == [studied.id])
        #expect(Set(try await reviewCards.all()) == Set(studiedCards))
    }

    // MARK: Template + store

    @Test func templateContract() throws {
        let template = DuplicatesTemplate(studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(template.modelTier == .standard)
        #expect(template.systemPrompt.contains("\"senses\""))
        #expect(template.outputJSONSchema.contains(#""enum":["duplicate","senses","different"]"#))
        let item = FixCardItem(id: "1", expression: "solid", translation: "твёрдый", example: "", synonyms: [], context: "")
        let message = template.userMessage(for: [DuplicateGroupItem(id: "g", cards: [item])])
        #expect(message.hasPrefix(#"{"groups":["#) && message.contains(#""id":"g""#) && message.contains(#""expression":"solid""#))
        let decoded = try template.decode(#"""
        {"groups":[
          {"id":"g","verdict":"senses","card":{"expression":" **solid** ","translation":"1) твёрдый 2) надёжный",
           "example":"1) solid rock. 2) a solid plan.","synonyms":["firm","hard","sound","reliable","stable"],
           "context":"Разные значения."}},
          {"id":"h","verdict":"duplicate","card":{"expression":"","translation":"x","example":"","synonyms":[],"context":""}}
        ]}
        """#)
        #expect(decoded.groups.map(\.id) == ["g"])                                   // an empty expression is dropped
        #expect(decoded.groups[0].card.expression == "solid" && decoded.groups[0].card.synonyms.count == 4)
    }

    @Test func notDuplicatesAreRemembered() async throws {
        let defaults = try #require(UserDefaults(suiteName: "dups-\(UUID().uuidString)"))
        let store = UserDefaultsDuplicateDismissalStore(defaults: defaults)
        await store.dismiss("a,b")
        await store.dismiss("a,b")
        #expect(await store.dismissed() == ["a,b"])
        #expect(await UserDefaultsDuplicateDismissalStore(defaults: defaults).dismissed() == ["a,b"])
    }
}

@Suite @MainActor struct DuplicatesScreenTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func phrase(_ en: String, _ ru: String, _ minute: Double) -> Domain.Expression {
        Domain.Expression(en: en, ru: ru, createdAt: now.addingTimeInterval(minute * 60))
    }

    private func newCards(_ e: Domain.Expression) -> [ReviewCard] {
        CardDirection.allCases.map { ReviewCard(expressionID: e.id, direction: $0, due: now) }
    }

    private func list(_ expressions: MockExpressionRepository, _ cards: MockReviewCardRepository,
                      duplicates: DuplicatesInteractor) -> StudyListViewModel {
        StudyListViewModel(
            studyList: StudyListInteractor(repository: expressions, cards: cards),
            saveExpression: SaveExpressionInteractor(enrich: EnrichExpressionInteractor(llm: MockLLMClient()),
                                                     repository: expressions),
            exportAlgoApp: ExportDeckInteractor(repository: expressions, exporter: AlgoAppXMLExporter()),
            exportAnki: ExportDeckInteractor(repository: expressions, exporter: AnkiExporter()),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            isConfigured: true, flashcards: FlashcardsInteractor(expressions: expressions, cards: cards),
            duplicates: duplicates, scope: .caught,
            studiedLanguage: { "English" }, nativeLanguage: { "Russian" })
    }

    private func wait(_ condition: () -> Bool) async throws {
        var tries = 0
        while !condition(), tries < 300 { tries += 1; try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Moving a look-alike from Caught asks first; Merge makes one card in flashcards.
    @Test func aCaughtLookAlikeAsksThenMerges() async throws {
        let existing = phrase("hit the roof", "взбеситься", 0), caught = phrase("Hit the roof!", "разозлиться", 1)
        let expressions = MockExpressionRepository(seed: [existing, caught])
        let cards = MockReviewCardRepository(seed: newCards(existing))
        let vm = list(expressions, cards, duplicates: DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions,
                                                                           cards: cards))
        await vm.load()
        #expect(vm.expressions.map(\.id) == [caught.id])

        vm.moveToFlashcards(caught)
        try await wait { vm.lookAlike != nil }
        let lookAlike = try #require(vm.lookAlike)
        #expect(lookAlike.existing.map(\.id) == [existing.id])
        #expect(vm.expressions.map(\.id) == [caught.id])                             // not moved yet

        vm.mergeIntoFlashcards(lookAlike)
        #expect(vm.isMerging)
        try await wait { !vm.isMerging }
        #expect(vm.expressions.isEmpty && vm.actionError == nil)
        let all = try await expressions.all()
        #expect(all.map(\.id) == [existing.id])
        #expect(all[0].ru == "1) взбеситься 2) разозлиться")                        // two meanings, numbered
        #expect(try await cards.all().count == 2)
    }

    /// Move separately; and Move all leaving the look-alikes on the list.
    @Test func moveSeparatelyAndMoveAllWithoutLookAlikes() async throws {
        let existing = phrase("hit the roof", "взбеситься", 0)
        let alike = phrase("to hit the roof", "разозлиться", 1), other = phrase("jump the gun", "поторопиться", 2)
        let expressions = MockExpressionRepository(seed: [existing, alike, other])
        let cards = MockReviewCardRepository(seed: newCards(existing))
        let vm = list(expressions, cards, duplicates: DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions,
                                                                           cards: cards))
        await vm.load()
        vm.prepareMoveAll()
        try await wait { vm.showMoveAllConfirmation }
        #expect(vm.moveAllLookAlikes == [alike.id])
        vm.moveAllToFlashcards(skippingLookAlikes: true)
        #expect(vm.expressions.map(\.id) == [alike.id])
        try await Task.sleep(for: .milliseconds(100))                                // let the move land
        #expect(Set(try await cards.all().map(\.expressionID)) == [existing.id, other.id])

        vm.moveToFlashcards(alike)
        try await wait { vm.lookAlike != nil }
        vm.moveSeparately(try #require(vm.lookAlike))
        #expect(vm.expressions.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(Set(try await cards.all().map(\.expressionID)) == [existing.id, other.id, alike.id])
    }

    /// The Find duplicates sheet: scan → Check → merge one group, keep the other apart — neither comes back.
    @Test func findDuplicatesSheet() async throws {
        let roof1 = phrase("hit the roof", "взбеситься", 0), roof2 = phrase("to hit the roof", "взбеситься", 1)
        let solid1 = phrase("solid", "надёжный", 2), solid2 = phrase("solid", "твёрдый", 3)
        let all = [roof1, roof2, solid1, solid2]
        let expressions = MockExpressionRepository(seed: all)
        let cards = MockReviewCardRepository(seed: all.flatMap(newCards))
        let duplicates = DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions, cards: cards)
        let vm = DuplicatesViewModel(duplicates: duplicates, studiedLanguage: { "English" }, nativeLanguage: { "Russian" })

        vm.start()
        try await wait { vm.phase != .scanning }
        #expect(vm.phase == .found && vm.groups.count == 2 && vm.unchecked.count == 2)
        vm.startCheck()
        try await wait { vm.phase != .checking }
        #expect(vm.phase == .checked && vm.verdicts.count == 2)
        #expect(vm.duplicateGroups.map(\.key) == ["hit the roof"])

        vm.mergeAllDuplicates()
        try await wait { vm.merged == 1 }
        vm.keepApart(try #require(vm.groups.first))
        #expect(vm.groups.isEmpty)
        #expect(try await expressions.all().count == 3)

        let again = DuplicatesViewModel(duplicates: duplicates, studiedLanguage: { "English" }, nativeLanguage: { "Russian" })
        again.start()
        try await wait { again.phase != .scanning }
        #expect(again.phase == .checked && again.groups.isEmpty)
    }
}

/// Answers call after call from a script: like the mock, or an error.
private final class ScriptedLLM: LLMClient, @unchecked Sendable {
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
