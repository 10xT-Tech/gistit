//
//  DuplicatesTests.swift
//  EnglishHelperTests
//
//  Duplicates: the comparison key (articles, "to", placeholders, punctuation, word forms), the scan
//  over flashcards (Caught left out, "not duplicates" hidden, progress, exact duplicates), the
//  model's check in batches (sent / answered, merges inside a group — look-alike isn't the same —
//  unusable answers, a stop), the merge (texts, which card each direction keeps, a caught phrase
//  merged into its flashcard), "not duplicates" links (kept with the cards, honoured by a search,
//  put to the model again by a full re-check, adopted from the first builds' UserDefaults, carried by
//  card files), a verb and a noun never look-alikes, the
//  template, and the screens: a look-alike moved from Caught (exact, by the model, or another phrase),
//  Move all without look-alikes, the Find duplicates sheet.
//

import Testing
import Foundation
import SwiftData
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
        // A slot is never dropped — it changes the expression; only its spellings are one.
        #expect(en("pick on sb") == en("to pick on someone"))
        #expect(en("pick on smb.") == "pick on someone")
        #expect(en("fuck about") != en("fuck somebody about"))
        #expect(en("wind (someone) up") == en("wind sb up"))
        #expect(en("wind up") != en("wind sb up"))
        #expect(en("lose one's temper") == en("lose sb's temper"))
        #expect(en("get sth done") == en("get something done"))
        #expect(en("very bright (future)") == "very bright")              // a gloss in brackets goes
        #expect(en("finish + -ing") == en("to finish doing"))
        #expect(en("stop + -ing") != en("stop + to"))
        #expect(en("the more…, the more…") == en("the more ... the more"))
        #expect(en("A Corkscrew") == en("corkscrew"))
        #expect(en("I’m off") == en("i'm off"))
        #expect(en("hit the road") != en("hit the roof"))
        #expect(en("something") == "something")
        #expect(PhraseKey.make("der Tisch", language: "German") == PhraseKey.make("Tisch", language: "German"))
        #expect(PhraseKey.make("l'Arbre", language: "French") == PhraseKey.make("arbre", language: "French"))
        #expect(PhraseKey.make("faire quelque chose", language: "French") == PhraseKey.make("faire qqch", language: "French"))
        #expect(PhraseKey.make("jdm helfen", language: "German") == "jemandem helfen")
        #expect(PhraseKey.make("café", language: "French") == "cafe")
    }

    @Test func wordClassByMarker() {
        let en = { PhraseKey.wordClass(of: $0, language: "English") }
        #expect(en("to drain") == .verb && en("To hit the roof") == .verb)
        #expect(en("a drain") == .noun && en("an apple") == .noun && en("the rip-off") == .noun)
        #expect(en("drain") == nil && en("hit the roof!") == nil && en("to") == nil)
        #expect(PhraseKey.wordClass(of: "sich freuen", language: "German") == .verb)
        #expect(PhraseKey.wordClass(of: "der Tisch", language: "German") == .noun)
        #expect(PhraseKey.wordClass(of: "s’asseoir", language: "French") == .verb)
        #expect(PhraseKey.wordClass(of: "l'arbre", language: "French") == .noun)
        #expect(PhraseKey.alike(.verb, nil) && PhraseKey.alike(.noun, .noun) && !PhraseKey.alike(.verb, .noun))
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
        // A single word keeps its form: "jumping" isn't "to jump".
        #expect(PhraseKey.make("jumping", language: "English", lemmatizer: Lemmas()) == "jumping")
        // `prepare` never waits for the asset download (it can hang for minutes): it returns at once,
        // and until the assets are there, words keep their written form.
        let natural = NaturalLanguageLemmatizer()
        let clock = ContinuousClock()
        let prepared = await clock.measure { await natural.prepare(language: "English") }
        #expect(prepared < .seconds(1))
        let lemmas = natural.lemmatize("jumping the gun", language: "English")
        #expect(lemmas == "jump the gun" || lemmas == "jumping the gun")
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
        #expect(groups[0].isExactOnly && groups[0].exact.first?.expressionIDs == [roof1.id, roof2.id])   // same translation
        #expect(groups[1].exact.isEmpty)

        let alike = try await sut.lookAlikesInFlashcards(for: [caught, unique], studiedLanguage: "English")
        #expect(alike[caught.id]?.map(\.id) == [roof1.id, roof2.id])
        #expect(alike[unique.id] == nil)                                             // only itself

        try await sut.markNotDuplicates(groups[1].expressions.map(\.id))             // "Don't merge"
        #expect(try await scan(sut)?.map(\.key) == ["hit the roof"])
        // A full re-check brings them back, marked.
        let full = try #require(try await scan(sut, full: true))
        #expect(full.map(\.key) == ["hit the roof", "solid"])
        #expect(full[1].isAllMarked && !full[1].honorsMarks && full[1].excluded.isEmpty)
    }

    /// "to drain" and "a drain" are two words — no group, no look-alike from Caught, no exact merge; with
    /// a bare "coat" next to "to coat" and "a coat" all three are one group (the bare one may be either);
    /// with no bare one the nouns group on their own.
    @Test func aVerbAndANounAreNotLookAlikes() async throws {
        let drainVerb = phrase("to drain", "сливать воду", 0), drainNoun = phrase("a drain", "слив", 1)
        let coatVerb = phrase("to coat", "покрывать", 2), coatNoun = phrase("a coat", "шерсть", 3)
        let coat = phrase("coat", "пальто", 4)
        let ripVerb = phrase("to rip off", "обмануть", 5), ripNoun = phrase("a rip-off", "обдираловка", 6)
        let ripNoun2 = phrase("the rip-off", "надувательство", 7)
        let studied = [drainVerb, drainNoun, coatVerb, coatNoun, coat, ripVerb, ripNoun, ripNoun2]
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: MockExpressionRepository(seed: studied),
                                       cards: MockReviewCardRepository(seed: studied.flatMap { cards($0) }))

        let groups = try #require(try await scan(sut, full: true))
        #expect(groups.map(\.key) == ["coat", "rip off|noun"])
        #expect(groups[0].expressions.map(\.id) == [coatVerb.id, coatNoun.id, coat.id])
        #expect(groups[1].expressions.map(\.id) == [ripNoun.id, ripNoun2.id])

        let drain = phrase("drain", "сток", 8), caughtNoun = phrase("A drain", "сток", 9)
        let alike = try await DuplicatesInteractor(
            llm: MockLLMClient(), expressions: MockExpressionRepository(seed: [drainVerb, drain, caughtNoun]),
            cards: MockReviewCardRepository(seed: [drainVerb].flatMap { cards($0) })
        ).lookAlikesInFlashcards(for: [drain, caughtNoun], studiedLanguage: "English")
        #expect(alike[drain.id]?.map(\.id) == [drainVerb.id])
        #expect(alike[caughtNoun.id] == nil)

        let sameTranslation = [phrase("to drain", "сток", 0), phrase("a drain", "сток", 1)]
        #expect(DuplicatesInteractor.exactMerges(among: sameTranslation, language: "English").isEmpty)
    }

    /// A new look-alike joins a marked pair: the group is offered again, but the marked pair is never
    /// proposed for merging — not as an exact duplicate, not from the model.
    @Test func aMarkedPairIsNeverProposed() async throws {
        let a = phrase("hit the roof", "взбеситься", 0), b = phrase("to hit the roof", "взбеситься", 1)
        let c = phrase("hit the roof!", "разозлиться", 2)
        let marks = InMemoryNotDuplicateMarks([NotDuplicatePair(a.id, b.id)])
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: MockExpressionRepository(seed: [a, b, c]),
                                       cards: MockReviewCardRepository(seed: [a, b, c].flatMap { cards($0) }),
                                       marks: marks)
        let group = try #require(try await scan(sut)?.first)
        #expect(group.expressions.count == 3 && !group.isAllMarked)
        #expect(group.exact.isEmpty)                                                 // a+b are exact, but marked
        var proposals: [String: [DuplicateMerge]] = [:]
        for try await step in sut.check([group], studiedLanguage: "English", nativeLanguage: "Russian") {
            proposals.merge(step.proposals) { _, new in new }
        }
        #expect(proposals[group.key] == [])                                          // the model's a+b dropped

        // Merged away, a phrase's links go with it.
        try await sut.merge([a, c], into: CardText(expression: "hit the roof", translation: "x", example: "",
                                                   synonyms: [], context: ""),
                            as: .duplicate, studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(try await marks.pairs() == [NotDuplicatePair(a.id, b.id)])
        try await sut.merge([b, a], into: CardText(expression: "hit the roof", translation: "x", example: "",
                                                   synonyms: [], context: ""),
                            as: .duplicate, studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(try await marks.pairs().isEmpty)
    }

    /// The first builds kept "not duplicates" in UserDefaults: a scan turns them into links, once.
    @Test func legacyDismissalsBecomeLinks() async throws {
        let a = phrase("solid", "надёжный", 0), b = phrase("solid", "твёрдый", 1)
        let defaults = try #require(UserDefaults(suiteName: "dups-\(UUID().uuidString)"))
        defaults.set([DuplicateGroup.memberID(of: [a.id, b.id])], forKey: "flashcardsNotDuplicates")
        let legacy = UserDefaultsDuplicateDismissalStore(defaults: defaults)
        let marks = InMemoryNotDuplicateMarks()
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: MockExpressionRepository(seed: [a, b]),
                                       cards: MockReviewCardRepository(seed: [a, b].flatMap { cards($0) }),
                                       marks: marks, legacyDismissals: legacy)
        #expect(try await scan(sut) == [])
        #expect(try await marks.pairs() == [NotDuplicatePair(a.id, b.id)])
        #expect(await legacy.dismissed().isEmpty)
    }

    @Test func scanReportsProgress() async throws {
        let studied = (0..<450).map { phrase("phrase \($0)", "фраза", Double($0)) }
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: MockExpressionRepository(seed: studied),
                                       cards: MockReviewCardRepository(seed: studied.flatMap { cards($0) }))
        var steps: [DuplicateScanStep] = []
        for try await step in sut.scan(studiedLanguage: "English", full: false) { steps.append(step) }
        #expect(steps.map(\.checked) == [0] + Array(stride(from: 50, through: 450, by: 50)))
        #expect(steps.last?.groups == [])
    }

    /// "fuck about" twice is an exact duplicate; "fuck somebody about" is another expression — not even
    /// a look-alike. Look-alike isn't the same either: "pick on sb" in another meaning is grouped, and
    /// the model merges only the cards that are one.
    @Test func lookAlikeIsNotTheSame() async throws {
        let a = phrase("fuck about", "выпендриваться", 0), b = phrase("fuck somebody about", "водить за нос", 1)
        let c = phrase("Fuck about!", "Выпендриваться", 2, example: "stop fucking about.")
        let d = phrase("pick on someone", "придираться", 3), e = phrase("to pick on sb", "дразнить", 4)
        let f = phrase("pick on smb", "придираться", 5)
        let all = [a, b, c, d, e, f]
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: MockExpressionRepository(seed: all),
                                       cards: MockReviewCardRepository(seed: all.flatMap { cards($0) }))
        let groups = try #require(try await scan(sut))
        #expect(groups.map { $0.expressions.map(\.id) } == [[a.id, c.id], [d.id, e.id, f.id]])
        #expect(groups[0].isExactOnly && groups[0].exact[0].card.example == "stop fucking about.")   // filled in
        let pick = groups[1]
        #expect(pick.exact.map(\.expressionIDs) == [[d.id, f.id]] && !pick.isExactOnly)

        var proposals: [String: [DuplicateMerge]] = [:]
        for try await step in sut.check([pick], studiedLanguage: "English", nativeLanguage: "Russian") {
            proposals.merge(step.proposals) { _, new in new }
        }
        let merges = try #require(proposals[pick.key])
        #expect(merges.map(\.expressionIDs) == [[d.id, f.id]] && merges[0].kind == .duplicate)      // e stays apart
    }

    /// A merge never drops the infinitive marker or article one of its cards had — exact or the model's.
    @Test func aMergeKeepsTheDictionaryForm() {
        let bare = phrase("hit the roof", "взбеситься", 0), marked = phrase("to hit the roof", "взбеситься", 1)
        #expect(DuplicatesInteractor.exactMerges(among: [bare, marked], language: "English")[0].card.expression
                == "to hit the roof")
        let card = CardText(expression: "Hit the roof!", translation: "x", example: "", synonyms: [], context: "")
        let verdict = DuplicateVerdict(id: "g", merges: [
            DuplicateMergeAnswer(ids: [bare.id.uuidString, marked.id.uuidString], verdict: .duplicate, card: card)])
        #expect(DuplicatesInteractor.merges(verdict, among: [bare, marked], language: "English")[0].card.expression
                == "to Hit the roof!")
        let keep = { DuplicatesInteractor.keepingMarker($0, of: $1, language: "English") }
        #expect(keep("a corkscrew", [phrase("corkscrew", "x", 0)]) == "a corkscrew")             // already has one
        #expect(keep("corkscrew", [phrase("A corkscrew", "x", 0)]) == "a corkscrew")
        #expect(keep("solid", [phrase("solid", "x", 0)]) == "solid")                              // nobody had one
        #expect(DuplicatesTemplate().systemPrompt.contains("\"to hit the roof\""))
    }

    /// The model's merges are kept to the group's own phrases, each in one merge, two or more each.
    @Test func modelMergesAreSanitised() {
        let a = phrase("solid", "твёрдый", 0), b = phrase("solid", "надёжный", 1), c = phrase("solid", "крепкий", 2)
        let card = CardText(expression: "solid", translation: "1) … 2) …", example: "", synonyms: [], context: "")
        let verdict = DuplicateVerdict(id: "g", merges: [
            DuplicateMergeAnswer(ids: [b.id.uuidString, a.id.uuidString, "stranger"], verdict: .senses, card: card),
            DuplicateMergeAnswer(ids: [a.id.uuidString, c.id.uuidString], verdict: .duplicate, card: card),   // a is taken
        ])
        let merges = DuplicatesInteractor.merges(verdict, among: [a, b, c])
        #expect(merges.map(\.expressionIDs) == [[a.id, b.id]])                       // oldest first; c stays apart
    }

    private func scan(_ sut: DuplicatesInteractor, full: Bool = false) async throws -> [DuplicateGroup]? {
        var groups: [DuplicateGroup]?
        for try await step in sut.scan(studiedLanguage: "English", full: full) { groups = step.groups ?? groups }
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

    /// Batches of five, three requests out at once: the first three go before any answer, the answers
    /// catch up (in whatever order they come).
    @Test func checkSendsBatchesAndCollectsVerdicts() async throws {
        let (studied, reviewCards) = twelveGroups()
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: MockExpressionRepository(seed: studied),
                                       cards: MockReviewCardRepository(seed: reviewCards))
        let groups = try #require(try await scan(sut))
        #expect(groups.count == 12)
        #expect(groups.filter(\.isExactOnly).count == 6)                             // the same translation
        var steps: [DuplicateCheckStep] = []
        for try await step in sut.check(groups, studiedLanguage: "English", nativeLanguage: "Russian") { steps.append(step) }
        #expect(steps.map(\.sent) == [0, 5, 10, 12, 12, 12, 12])
        #expect(steps.prefix(4).allSatisfy { $0.answered == 0 })
        #expect(steps.allSatisfy { $0.answered <= $0.sent })
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.answered <= $1.answered } && steps.last?.answered == 12)
        let proposals = steps.reduce(into: [String: [DuplicateMerge]]()) { $0.merge($1.proposals) { _, new in new } }
        #expect(proposals.count == 12)
        let first = try #require(proposals[groups[0].key]), second = try #require(proposals[groups[1].key])
        #expect(first.count == 1 && first[0].kind == .duplicate && first[0].card.translation == "фраза 0")
        #expect(second.isEmpty)                                                      // two phrases after all
    }

    /// An unusable answer (twice) leaves its batch unchecked and the check goes on; going offline stops
    /// it.
    @Test func unusableAnswersAndAStop() async throws {
        let (studied, reviewCards) = twelveGroups()
        let finder = DuplicatesInteractor(llm: MockLLMClient(), expressions: MockExpressionRepository(seed: studied),
                                          cards: MockReviewCardRepository(seed: reviewCards))
        let groups = try #require(try await scan(finder))
        let sut = DuplicatesInteractor(llm: RejectingLLM(rejected: [groups[0].key]),     // its batch: groups 0–4
                                       expressions: MockExpressionRepository(seed: studied),
                                       cards: MockReviewCardRepository(seed: reviewCards))
        var steps: [DuplicateCheckStep] = []
        for try await step in sut.check(groups, studiedLanguage: "English", nativeLanguage: "Russian") { steps.append(step) }
        #expect(steps.last?.failed == 5)
        #expect(steps.last?.answered == 12)
        #expect(Set(steps.flatMap { $0.proposals.keys }) == Set(groups.dropFirst(5).map(\.key)))

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
        #expect(template.systemPrompt.contains("\"fuck somebody about\" are two expressions"))
        #expect(template.outputJSONSchema.contains(#""enum":["duplicate","senses"]"#))
        let item = FixCardItem(id: "1", expression: "solid", translation: "твёрдый", example: "", synonyms: [], context: "")
        let message = template.userMessage(for: [DuplicateGroupItem(id: "g", cards: [item])])
        #expect(message.hasPrefix(#"{"groups":["#) && message.contains(#""id":"g""#) && message.contains(#""expression":"solid""#))
        let decoded = try template.decode(#"""
        {"groups":[
          {"id":"g","merges":[
            {"ids":["1","2","2"],"verdict":"senses","card":{"expression":" **solid** ","translation":"1) твёрдый 2) надёжный",
             "example":"1) solid rock. 2) a solid plan.","synonyms":["firm","hard","sound","reliable","stable"],
             "context":"Разные значения."}},
            {"ids":["3"],"verdict":"duplicate","card":{"expression":"x","translation":"y","example":"","synonyms":[],"context":""}},
            {"ids":["3","4"],"verdict":"duplicate","card":{"expression":"","translation":"y","example":"","synonyms":[],"context":""}}
          ]},
          {"id":"h","merges":[]}
        ]}
        """#)
        #expect(decoded.groups.map(\.id) == ["g", "h"])
        let merges = decoded.groups[0].merges
        #expect(merges.map(\.ids) == [["1", "2"]])                                   // a lone card, an empty expression: dropped
        #expect(merges[0].card.expression == "solid" && merges[0].card.synonyms.count == 4)
    }

    /// The links live in the store with the cards (schema V5) and survive reopening it.
    @Test func linksAreKeptWithTheCards() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "marks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "s.store")
        let a = UUID(), b = UUID(), c = UUID()
        func open() throws -> SwiftDataNotDuplicateMarks {
            let schema = PersistenceSchema.current
            let container = try ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self,
                                               configurations: ModelConfiguration(schema: schema, url: url))
            return SwiftDataNotDuplicateMarks(modelContainer: container)
        }
        let marks = try open()
        try await marks.mark(NotDuplicatePair.all(among: [a, b, c]))
        try await marks.mark([NotDuplicatePair(b, a)])                                // the same pair, either way round
        #expect(try await marks.pairs().count == 3)
        try await marks.unmark(involving: [c])
        #expect(try await open().pairs() == [NotDuplicatePair(a, b)])
    }

    /// A card file carries the links by expression; importing it on another device links again.
    @Test func cardFilesCarryTheLinks() async throws {
        let a = phrase("solid", "надёжный", 0), b = phrase("a solid", "твёрдый", 1), c = phrase("jump the gun", "x", 2)
        let source = CardTransferInteractor(expressions: MockExpressionRepository(seed: [a, b, c]),
                                            cards: MockReviewCardRepository(seed: [a, b, c].flatMap { cards($0) }),
                                            marks: InMemoryNotDuplicateMarks([NotDuplicatePair(a.id, b.id)]))
        let file = try CardFile.decode(try await source.exportFlashcards(now: now).encoded())
        #expect(file.cards.map(\.notDuplicateOf) == [["a solid"], ["solid"], nil])

        let expressions = MockExpressionRepository(seed: [])
        let marks = InMemoryNotDuplicateMarks()
        _ = try await CardTransferInteractor(expressions: expressions, cards: MockReviewCardRepository(), marks: marks)
            .importIntoFlashcards(file, now: now)
        let imported = Dictionary(uniqueKeysWithValues: try await expressions.all().map { ($0.ru, $0.id) })
        #expect(try await marks.pairs() == [NotDuplicatePair(try #require(imported["надёжный"]), try #require(imported["твёрдый"]))])
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

    /// Moving a look-alike from Caught asks first; Merge makes one card in flashcards — here the same
    /// phrase in another meaning, numbered.
    @Test func aCaughtLookAlikeAsksThenMerges() async throws {
        let existing = phrase("hit the roof", "взбеситься", 0), caught = phrase("hit the roof", "разозлиться", 1)
        let expressions = MockExpressionRepository(seed: [existing, caught])
        let cards = MockReviewCardRepository(seed: newCards(existing))
        let vm = list(expressions, cards, duplicates: DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions,
                                                                           cards: cards))
        await vm.load()
        #expect(vm.expressions.map(\.id) == [caught.id])

        vm.moveToFlashcards(caught)
        #expect(vm.expressions.isEmpty)                                              // the row goes at once…
        try await wait { vm.lookAlike != nil }
        let lookAlike = try #require(vm.lookAlike)
        #expect(lookAlike.existing.map(\.id) == [existing.id])
        #expect(vm.expressions.map(\.id) == [caught.id])                             // …and comes back to ask

        vm.mergeIntoFlashcards(lookAlike)
        #expect(vm.isMerging)
        try await wait { !vm.isMerging }
        #expect(vm.expressions.isEmpty && vm.actionError == nil)
        let all = try await expressions.all()
        #expect(all.map(\.id) == [existing.id])
        #expect(all[0].ru == "1) взбеситься 2) разозлиться")                        // two meanings, numbered
        #expect(try await cards.all().count == 2)
    }

    /// An exact duplicate merges on the device; a look-alike that's another phrase asks to move apart.
    @Test func exactDuplicateAndAnotherPhrase() async throws {
        let existing = phrase("fuck about", "выпендриваться", 0), other = phrase("fuck about", "бездельничать", 1)
        let exact = phrase("Fuck about!", "Выпендриваться", 2), different = phrase("to fuck about", "валять дурака", 3)
        let expressions = MockExpressionRepository(seed: [existing, other, exact, different])
        let cards = MockReviewCardRepository(seed: newCards(existing) + newCards(other))
        let llm = CountingLLM()
        let vm = list(expressions, cards, duplicates: DuplicatesInteractor(llm: llm, expressions: expressions, cards: cards))
        await vm.load()

        vm.moveToFlashcards(exact)
        try await wait { vm.lookAlike != nil }
        #expect(vm.lookAlike?.existing.map(\.id) == [existing.id, other.id])
        vm.mergeIntoFlashcards(try #require(vm.lookAlike))
        try await wait { !vm.isMerging }
        #expect(llm.calls == 0)                                                      // no model for an exact one
        #expect(try await expressions.all().contains { $0.id == exact.id } == false)
        #expect(try await expressions.all().contains { $0.id == other.id })          // untouched

        vm.moveToFlashcards(different)
        try await wait { vm.lookAlike != nil }
        #expect(vm.lookAlike?.existing.map(\.id) == [existing.id, other.id])
        vm.mergeIntoFlashcards(try #require(vm.lookAlike))
        try await wait { vm.notADuplicate != nil }                                   // the model merged nothing
        #expect(llm.calls == 1)
        vm.moveSeparately(try #require(vm.notADuplicate))
        try await Task.sleep(for: .milliseconds(100))
        #expect(Set(try await cards.all().map(\.expressionID)) == [existing.id, other.id, different.id])
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
        #expect(vm.isCheckingLookAlikes)                                             // "Looking for look-alikes…"
        try await wait { vm.showMoveAllConfirmation }
        #expect(!vm.isCheckingLookAlikes)
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

    /// The Find duplicates sheet: exact pairs merge without the model ("fuck about" twice — "fuck
    /// somebody about" isn't in the group at all); Check proposes the rest — "pick on sb" twice merges and
    /// the third "pick on" is left apart for good; "solid" in two meanings is kept apart by the user.
    /// Nothing comes back on the next scan.
    @Test func findDuplicatesSheet() async throws {
        let roof1 = phrase("hit the roof", "взбеситься", 0), roof2 = phrase("to hit the roof", "взбеситься", 1)
        let solid1 = phrase("solid", "надёжный", 2), solid2 = phrase("solid", "твёрдый", 3)
        let about1 = phrase("fuck about", "выпендриваться", 4), aboutSomebody = phrase("fuck somebody about", "водить за нос", 5)
        let about2 = phrase("to fuck about", "Выпендриваться", 6)
        let pick1 = phrase("pick on sb", "придираться", 7), pick2 = phrase("pick on someone", "дразнить", 8)
        let pick3 = phrase("to pick on smb", "придираться", 9)
        let all = [roof1, roof2, solid1, solid2, about1, aboutSomebody, about2, pick1, pick2, pick3]
        let expressions = MockExpressionRepository(seed: all)
        let cards = MockReviewCardRepository(seed: all.flatMap(newCards))
        let duplicates = DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions, cards: cards)
        let vm = DuplicatesViewModel(duplicates: duplicates, studiedLanguage: { "English" }, nativeLanguage: { "Russian" })

        vm.start()
        try await wait { vm.phase != .scanning }
        #expect(vm.phase == .found && vm.groups.map(\.key) == ["hit the roof", "solid", "fuck about", "pick on someone"])
        #expect(vm.unchecked.map(\.key) == ["solid", "pick on someone"])            // the roof and "fuck about" are exact
        #expect(vm.duplicateMerges.count == 3)                                       // the exact pairs, "pick on" too

        vm.startCheck()
        try await wait { vm.phase != .checking }
        #expect(vm.phase == .checked && vm.checkedKeys == ["solid", "pick on someone"])
        #expect(vm.proposals["solid"]?.first?.kind == .senses)
        #expect(vm.proposals["pick on someone"]?.map(\.expressionIDs) == [[pick1.id, pick3.id]])

        vm.mergeAllDuplicates()
        try await wait { vm.merged == 3 }
        #expect(vm.groups.map(\.key) == ["solid"])                                   // the other "pick on" is apart
        vm.keepApart(try #require(vm.groups.first))
        #expect(vm.groups.isEmpty)
        #expect(Set(try await expressions.all().map(\.id))
                == [roof1.id, solid1.id, solid2.id, about1.id, aboutSomebody.id, pick1.id, pick2.id])

        try await Task.sleep(for: .milliseconds(50))
        let again = DuplicatesViewModel(duplicates: duplicates, studiedLanguage: { "English" }, nativeLanguage: { "Russian" })
        again.start()
        try await wait { again.phase != .scanning }
        #expect(again.phase == .checked && again.groups.isEmpty)

        // A full re-check puts both marked groups to the model, showing none until it answers…
        again.rescanFully()
        try await wait { again.phase != .scanning }
        #expect(again.isFull && again.groups.map(\.key) == ["solid", "pick on someone"])
        let allMarked = again.groups.allSatisfy { $0.isAllMarked }
        #expect(allMarked)
        #expect(again.shownGroups.isEmpty && again.markedToCheck == 2)
        #expect(again.unchecked.count == 2)
        // …then only the one it proposes a merge in ("solid": two meanings); the other stays marked.
        again.startCheck()
        try await wait { again.phase != .checking }
        #expect(again.shownGroups.map(\.key) == ["solid"] && again.confirmedApart == 1)
        #expect(again.proposals["solid"]?.first?.kind == .senses)
        #expect(again.duplicateMerges.isEmpty)                                       // no bulk merge of marked pairs
    }
}

/// Answers like the mock, counting the calls.
private final class CountingLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        lock.withLock { count += 1 }
        return try await MockLLMClient().run(template, input: input)
    }
}

/// Answers like the mock — but never usefully for a batch holding one of the `rejected` groups.
private struct RejectingLLM: LLMClient {
    let rejected: Set<String>

    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        if let groups = input as? [DuplicateGroupItem], groups.contains(where: { rejected.contains($0.id) }) {
            throw LLMError.invalidOutput("unusable")
        }
        return try await MockLLMClient().run(template, input: input)
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
