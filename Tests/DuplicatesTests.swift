//
//  DuplicatesTests.swift
//  EnglishHelperTests
//
//  Duplicates: the comparison key (articles, "to", placeholders, punctuation, word forms), the scan
//  over flashcards (Caught left out, "not duplicates" hidden, progress, exact duplicates), the
//  model's check (one request for a batch: merges inside a group — look-alike isn't the same — an
//  unusable answer, a service that doesn't answer), the merge (texts, which card each direction keeps, a caught phrase
//  merged into its flashcard), "not duplicates" links (kept with the cards, honoured by a search,
//  put to the model again by a full re-check, adopted from the first builds' UserDefaults, carried by
//  card files), a verb and a noun never look-alikes, the
//  template, and the screens: a look-alike moved from Caught (exact, by the model, or another phrase),
//  Move all without look-alikes, the Find duplicates sheet — and what may run at the same time in it:
//  "Merge all" as one run (two taps, the groups' own buttons, a full re-check, Stop), a group out for
//  checking waiting for its answer, an answer about a group that changed since, closing the sheet
//  with a merge under way; and the sheet's one line to the model — batches of five, three requests at
//  once, "Check" and the groups' own Check together (nobody asked twice), Stop, a dead service, a batch
//  without an answer.
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
        let proposals = try await sut.check([group], studiedLanguage: "English", nativeLanguage: "Russian")
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

        let proposals = try await sut.check([pick], studiedLanguage: "English", nativeLanguage: "Russian")
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

    /// A check is ONE request for the batch it's given (the sheet keeps the line: `DuplicatesScreenTests`),
    /// answered per group.
    @Test func aCheckIsOneRequestForItsBatch() async throws {
        let (studied, reviewCards) = twelveGroups()
        let llm = CountingLLM()
        let sut = DuplicatesInteractor(llm: llm, expressions: MockExpressionRepository(seed: studied),
                                       cards: MockReviewCardRepository(seed: reviewCards))
        let groups = try #require(try await scan(sut))
        #expect(groups.count == 12)
        #expect(groups.filter(\.isExactOnly).count == 6)                             // the same translation
        let proposals = try await sut.check(Array(groups.prefix(5)), studiedLanguage: "English", nativeLanguage: "Russian")
        #expect(llm.calls == 1)
        #expect(Set(proposals.keys) == Set(groups.prefix(5).map(\.key)))
        let first = try #require(proposals[groups[0].key]), second = try #require(proposals[groups[1].key])
        #expect(first.count == 1 && first[0].kind == .duplicate && first[0].card.translation == "фраза 0")
        #expect(second.isEmpty)                                                      // two phrases after all
        #expect(try await sut.check([], studiedLanguage: "English", nativeLanguage: "Russian").isEmpty)
        #expect(llm.calls == 1)                                                      // nothing to ask: no request
    }

    /// No answer for the batch (unusable twice, or the request refused): its groups are missing from
    /// the result — they stay unchecked, the caller's Check goes on. A service that doesn't answer
    /// (asked twice), or no network, THROWS: the caller's Check stops there.
    @Test func aCheckWithoutAnAnswerAndAServiceThatIsDown() async throws {
        let (studied, reviewCards) = twelveGroups()
        let finder = DuplicatesInteractor(llm: MockLLMClient(), expressions: MockExpressionRepository(seed: studied),
                                          cards: MockReviewCardRepository(seed: reviewCards))
        let batch = Array(try #require(try await scan(finder)).prefix(5))
        func interactor(_ llm: any LLMClient) -> DuplicatesInteractor {
            DuplicatesInteractor(llm: llm, expressions: MockExpressionRepository(seed: studied),
                                 cards: MockReviewCardRepository(seed: reviewCards))
        }
        func check(_ llm: any LLMClient) async throws -> [String: [DuplicateMerge]] {
            try await interactor(llm).check(batch, studiedLanguage: "English", nativeLanguage: "Russian")
        }

        #expect(try await check(RejectingLLM(rejected: [batch[0].key])).isEmpty)
        let refused = ScriptedLLM(script: [.failure(LLMError.requestRejected("HTTP 400"))])
        #expect(try await check(refused).isEmpty)
        #expect(refused.calls == 1)                                                  // the same content again can't help
        // One unusable answer, then a good one: the second try is the answer.
        #expect(try await check(ScriptedLLM(script: [.failure(LLMError.invalidOutput("cut"))])).count == 5)

        await #expect(throws: LLMError.offline) { _ = try await check(ScriptedLLM(script: [.failure(LLMError.offline)])) }
        let down = ScriptedLLM(script: Array(repeating: .failure(LLMError.overloaded), count: 6))
        await #expect(throws: LLMError.overloaded) { _ = try await check(down) }
        #expect(down.calls == 2)                                                     // asked twice, no more
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
                      duplicates: any DuplicatesUseCase, scope: StudyListViewModel.Scope = .caught) -> StudyListViewModel {
        StudyListViewModel(
            studyList: StudyListInteractor(repository: expressions, cards: cards),
            saveExpression: SaveExpressionInteractor(enrich: EnrichExpressionInteractor(llm: MockLLMClient()),
                                                     repository: expressions),
            exportAlgoApp: ExportDeckInteractor(repository: expressions, exporter: AlgoAppXMLExporter()),
            exportAnki: ExportDeckInteractor(repository: expressions, exporter: AnkiExporter()),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            isConfigured: true, flashcards: FlashcardsInteractor(expressions: expressions, cards: cards),
            fixCards: FixCardsInteractor(llm: MockLLMClient(), expressions: expressions, cards: cards),
            duplicates: duplicates, scope: scope,
            studiedLanguage: { "English" }, nativeLanguage: { "Russian" })
    }

    /// `count` exact pairs ("word" / "to word", one translation), each its own group.
    private func exactPairs(_ count: Int) -> [Domain.Expression] {
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"]
        return words.prefix(count).enumerated().flatMap { index, word in
            [phrase(word, "перевод \(index)", Double(index * 2)), phrase("to \(word)", "перевод \(index)", Double(index * 2 + 1))]
        }
    }

    /// The sheet over `all` in flashcards, its merges taking a little time (and counted).
    private func sheet(_ all: [Domain.Expression], llm: any LLMClient = MockLLMClient())
        -> (DuplicatesViewModel, SlowMerges, MockExpressionRepository) {
        let expressions = MockExpressionRepository(seed: all)
        let cards = MockReviewCardRepository(seed: all.flatMap(newCards))
        let duplicates = SlowMerges(DuplicatesInteractor(llm: llm, expressions: expressions, cards: cards))
        let vm = DuplicatesViewModel(duplicates: duplicates, studiedLanguage: { "English" }, nativeLanguage: { "Russian" },
                                     gatherDelay: .milliseconds(20))
        return (vm, duplicates, expressions)
    }

    /// `count` groups of one word in two meanings: nothing exact, each group has a Check of its own.
    private func twoMeanings(_ count: Int) -> [Domain.Expression] {
        (0..<count).flatMap { index in
            [phrase("word \(index)", "значение \(index) а", Double(index * 2)),
             phrase("word \(index)", "значение \(index) б", Double(index * 2 + 1))]
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        var tries = 0
        while !condition(), tries < 300 { tries += 1; try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Until the merge sheet has its card (or its failure).
    private func waitForMerge(_ vm: StudyListViewModel) async throws {
        try await wait {
            guard let offer = vm.mergeOffer else { return false }
            if case .preparing = offer.stage { return false }
            return true
        }
    }

    /// Moving a look-alike from Caught works the merge out at once and shows the card it makes; Merge
    /// writes it — here the same phrase in another meaning, numbered.
    @Test func aCaughtLookAlikeAsksThenMerges() async throws {
        let existing = phrase("hit the roof", "взбеситься", 0), caught = phrase("hit the roof", "разозлиться", 1)
        let expressions = MockExpressionRepository(seed: [existing, caught])
        let cards = MockReviewCardRepository(seed: newCards(existing))
        let vm = list(expressions, cards, duplicates: DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions,
                                                                           cards: cards))
        await vm.load()
        #expect(vm.expressions.map(\.id) == [caught.id])

        vm.moveToFlashcards(caught)
        #expect(vm.isMoving(caught))                                                 // the row shows it's moving…
        try await waitForMerge(vm)
        let offer = try #require(vm.mergeOffer)
        #expect(offer.existing.map(\.id) == [existing.id])
        guard case .ready(let merge) = offer.stage else { Issue.record("no merge"); return }
        #expect(merge.card.translation == "1) взбеситься 2) разозлиться")             // shown before it's made
        #expect(vm.expressions.map(\.id) == [caught.id])                             // …and comes back to ask

        vm.confirmMerge()
        #expect(vm.isMerging)
        try await wait { !vm.isMerging }
        #expect(vm.expressions.isEmpty && vm.actionError == nil)
        let all = try await expressions.all()
        #expect(all.map(\.id) == [existing.id])
        #expect(all[0].ru == "1) взбеситься 2) разозлиться")                        // two meanings, numbered
        #expect(try await cards.all().count == 2)
    }

    /// An exact duplicate merges on the device; a look-alike the model calls another phrase is merged
    /// all the same — "Merge" is the user's decision — as one more meaning of the oldest look-alike.
    @Test func exactDuplicateAndAnotherPhrase() async throws {
        let existing = phrase("fuck about", "выпендриваться", 0), other = phrase("fuck about", "бездельничать", 1)
        let exact = phrase("Fuck about!", "Выпендриваться", 2), different = phrase("to fuck about", "валять дурака", 3)
        let expressions = MockExpressionRepository(seed: [existing, other, exact, different])
        let cards = MockReviewCardRepository(seed: newCards(existing) + newCards(other))
        let llm = CountingLLM()
        let vm = list(expressions, cards, duplicates: DuplicatesInteractor(llm: llm, expressions: expressions, cards: cards))
        await vm.load()

        vm.moveToFlashcards(exact)
        try await waitForMerge(vm)
        #expect(vm.mergeOffer?.existing.map(\.id) == [existing.id, other.id])
        vm.confirmMerge()
        try await wait { !vm.isMerging }
        #expect(llm.calls == 0)                                                      // no model for an exact one
        #expect(try await expressions.all().contains { $0.id == exact.id } == false)
        #expect(try await expressions.all().contains { $0.id == other.id })          // untouched

        vm.moveToFlashcards(different)
        try await waitForMerge(vm)
        #expect(vm.mergeOffer?.existing.map(\.id) == [existing.id, other.id])
        vm.confirmMerge()
        try await wait { !vm.isMerging }
        #expect(llm.calls == 1)                                                      // asked — it named no merge
        #expect(vm.expressions.isEmpty && vm.actionError == nil)                     // merged, and gone from Caught
        let left = try await expressions.all()
        #expect(Set(left.map(\.id)) == [existing.id, other.id])
        #expect(left.first { $0.id == existing.id }?.ru == "1) выпендриваться 2) валять дурака")
        #expect(left.first { $0.id == existing.id }?.en == "to fuck about")          // the dictionary form is kept
        #expect(left.first { $0.id == other.id }?.ru == "бездельничать")             // the other look-alike untouched
        #expect(Set(try await cards.all().map(\.expressionID)) == [existing.id, other.id])
    }

    /// The model can't be reached (offline, no answer, the plan's limit): nothing is merged — the
    /// phrase stays on Caught, untouched, and the screen shows the error.
    @Test func aFailedCheckStopsTheMerge() async throws {
        let existing = Domain.Expression(en: "hit the roof", ru: "взбеситься", example: "dad hit the roof.",
                                         createdAt: now)
        let caught = Domain.Expression(en: "to hit the roof", ru: "разозлиться", example: "she hit the roof.",
                                       createdAt: now.addingTimeInterval(60))
        let expressions = MockExpressionRepository(seed: [existing, caught])
        let cards = MockReviewCardRepository(seed: newCards(existing))
        let sut = DuplicatesInteractor(llm: RejectingLLM(rejected: [DuplicateGroup.memberID(of: [existing.id, caught.id])]),
                                       expressions: expressions, cards: cards)
        await #expect(throws: LLMError.self) {
            try await sut.mergeCaught(caught, into: [existing], studiedLanguage: "English", nativeLanguage: "Russian")
        }
        #expect(Set(try await expressions.all()) == [existing, caught])              // not a letter changed
        #expect(try await cards.all().count == 2)

        let vm = list(expressions, cards, duplicates: sut)
        await vm.load()
        vm.moveToFlashcards(caught)
        try await waitForMerge(vm)
        guard case .failed = vm.mergeOffer?.stage else { Issue.record("not failed"); return }   // the sheet says why
        vm.confirmMerge()                                                            // nothing to confirm
        #expect(!vm.isMerging && vm.mergeOffer != nil)
        vm.mergeOffer = nil                                                          // Cancel
        #expect(vm.expressions.map(\.id) == [caught.id] && vm.isLookAlike(caught))   // still on Caught, marked

        // The card the device words when the model answered and named no merge: numbered meanings.
        let forced = DuplicatesInteractor.forcedMerge(of: caught, into: existing, language: "English")
        #expect(forced.kind == .senses && forced.card.expression == "to hit the roof")
        #expect(forced.card.translation == "1) взбеситься 2) разозлиться")
        #expect(forced.card.example == "1) dad hit the roof. 2) she hit the roof.")

        // One more meaning onto a card that already numbers them; the same translation isn't repeated.
        #expect(DuplicatesInteractor.numbered("1) взбеситься 2) разозлиться", adding: "вспылить")
                == "1) взбеситься 2) разозлиться 3) вспылить")
        let same = DuplicatesInteractor.forcedMerge(of: phrase("hit the roof!", "Взбеситься", 2), into: existing,
                                                    language: "English")
        #expect(same.kind == .duplicate && same.card.translation == "взбеситься")
    }

    /// "Move new" moves the new phrases at once and leaves the look-alikes; one of them, added as a
    /// separate card, is written afresh, moved, and linked to its look-alike as "not duplicates".
    @Test func moveNewThenAddALookAlikeSeparately() async throws {
        let existing = phrase("hit the roof", "взбеситься", 0)
        let alike = phrase("to hit the roof", "разозлиться", 1), other = phrase("jump the gun", "поторопиться", 2)
        let expressions = MockExpressionRepository(seed: [existing, alike, other])
        let cards = MockReviewCardRepository(seed: newCards(existing))
        let duplicates = DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions, cards: cards)
        let vm = list(expressions, cards, duplicates: duplicates)
        await vm.load()
        #expect(vm.newPhrases.map(\.id) == [other.id])
        vm.moveNewToFlashcards()
        try await wait { vm.bulkMove == nil && vm.movingIDs.isEmpty }
        #expect(vm.expressions.map(\.id) == [alike.id])
        #expect(Set(try await cards.all().map(\.expressionID)) == [existing.id, other.id])

        #expect(vm.isLookAlike(alike))                                               // its row stays marked
        vm.moveToFlashcards(alike)
        try await waitForMerge(vm)
        vm.addSeparately()
        try await wait { vm.expressions.isEmpty }
        #expect(vm.expressions.isEmpty)
        #expect(Set(try await cards.all().map(\.expressionID)) == [existing.id, other.id, alike.id])
        #expect(try await expressions.all().first { $0.id == alike.id }?.ru.isEmpty == false)   // written by the model
        let links = try await duplicates.notDuplicates()
        #expect(links.contains(NotDuplicatePair(alike.id, existing.id)))
    }

    /// The row is marked as soon as the list loads (no move or "Move all" check needed), and a move
    /// that comes back to ask keeps it marked.
    @Test func aMoveThatAsksMarksTheRow() async throws {
        let existing = phrase("hit the roof", "взбеситься", 0)
        let alike = phrase("to hit the roof", "разозлиться", 1), other = phrase("jump the gun", "поторопиться", 2)
        let expressions = MockExpressionRepository(seed: [existing, alike, other])
        let cards = MockReviewCardRepository(seed: newCards(existing))
        let vm = list(expressions, cards, duplicates: DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions,
                                                                           cards: cards))
        await vm.load()
        #expect(vm.isLookAlike(alike) && vm.mark(alike) == .lookAlike && vm.mark(other) == .new)
        vm.moveToFlashcards(alike)
        try await waitForMerge(vm)
        vm.mergeOffer = nil                                                          // Cancel
        #expect(vm.isLookAlike(alike) && !vm.isLookAlike(other))
        #expect(vm.expressions.contains { $0.id == alike.id })
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

    /// "Merge all" is ONE run: a second tap, the groups' own Merge / Don't merge and a full re-check
    /// wait for it — every merge is made once, and the count says what was merged. (Two taps made every
    /// merge twice and showed "Merged: 40" of 20; a full re-check made it skip the rest silently.)
    @Test func mergeAllIsOneRun() async throws {
        let (vm, duplicates, expressions) = sheet(exactPairs(10))
        vm.start()
        try await wait { vm.phase != .scanning }
        #expect(vm.duplicateMerges.count == 10 && !vm.isBusy)
        let first = try #require(vm.groups.first), last = try #require(vm.groups.last)

        vm.mergeAllDuplicates()
        #expect(vm.mergeAll?.done == 0 && vm.mergeAll?.total == 10 && vm.isBusy)     // at once: Stop, not Done
        #expect(vm.busy == Set(vm.groups.map(\.key)))                                // their own buttons wait
        vm.mergeAllDuplicates()                                                      // a second tap
        vm.mergeGroup(first)                                                         // the group's own Merge
        vm.keepApart(last)                                                           // …and Don't merge
        vm.rescanFully()                                                             // a full re-check
        vm.startCheck()
        #expect(vm.phase == .found && vm.groups.count == 10 && !vm.isFull)

        try await wait { vm.mergeAll != nil && vm.mergeAll?.done ?? 0 >= 3 }
        #expect(vm.busy.count < 10)                                                  // a merged group is free again
        try await wait { vm.mergeAll == nil }
        #expect(duplicates.merges.count == 10 && Set(duplicates.merges).count == 10) // each once
        #expect(duplicates.mostAtOnce == 1)
        #expect(vm.merged == 10 && vm.groups.isEmpty && vm.busy.isEmpty && !vm.isBusy)
        #expect(try await expressions.all().count == 10)
        #expect(try await duplicates.notDuplicates().isEmpty)                        // "Don't merge" didn't get in
    }

    /// Stop ends "Merge all" after the merge under way; the rest stay proposed, free to be merged later.
    @Test func mergeAllStops() async throws {
        let (vm, duplicates, expressions) = sheet(exactPairs(10))
        duplicates.holdFrom = 3                                                      // the third merge is under way…
        vm.start()
        try await wait { vm.phase != .scanning }
        vm.mergeAllDuplicates()
        try await wait { duplicates.merges.count == 3 }
        vm.stop()                                                                    // …when Stop is tapped
        duplicates.release()
        await vm.settle()
        let made = duplicates.merges.count
        #expect(made == 3 && vm.merged == 3)                                         // it's finished, no fourth
        #expect(vm.mergeAll == nil && vm.busy.isEmpty && !vm.isBusy)
        #expect(vm.groups.count == 10 - made && vm.duplicateMerges.count == 10 - made)
        try await Task.sleep(for: .milliseconds(100))
        #expect(duplicates.merges.count == made)                                     // nothing goes on behind
        #expect(try await expressions.all().count == 20 - made)

        vm.mergeAllDuplicates()                                                      // the rest, later
        try await wait { vm.mergeAll == nil }
        #expect(vm.merged == 10 && vm.groups.isEmpty)
    }

    /// A merge that fails ends "Merge all" there, with the message — the rest stay as they were.
    @Test func aFailedMergeEndsMergeAll() async throws {
        let (vm, duplicates, _) = sheet(exactPairs(10))
        duplicates.failFrom = 3
        vm.start()
        try await wait { vm.phase != .scanning }
        vm.mergeAllDuplicates()
        try await wait { vm.mergeAll == nil }
        #expect(vm.merged == 3 && duplicates.merges.count == 4)                      // the 4th failed, no 5th
        #expect(vm.errorMessage != nil && vm.groups.count == 7 && vm.busy.isEmpty)
    }

    /// A group the Check has asked the model about keeps its Merge until the answer comes — its exact
    /// pair isn't merged from under the question (by the group's button or by "Merge all"), and nobody
    /// asks about it twice. Once answered it merges as proposed.
    @Test func aGroupOutForCheckingWaitsForItsAnswer() async throws {
        let pick1 = phrase("pick on sb", "придираться", 0), pick2 = phrase("pick on someone", "дразнить", 1)
        let pick3 = phrase("to pick on smb", "придираться", 2)
        let llm = SlowLLM()
        let (vm, duplicates, expressions) = sheet([pick1, pick2, pick3], llm: llm)
        vm.start()
        try await wait { vm.phase != .scanning }
        let group = try #require(vm.groups.first)
        #expect(vm.duplicateMerges.count == 1)                                       // the exact pair, at once

        vm.startCheck()
        #expect(vm.awaiting == [group.key] && vm.duplicateMerges.isEmpty)
        vm.mergeGroup(group)
        vm.mergeAllDuplicates()
        vm.checkGroup(group)
        try await wait { vm.phase != .checking }
        #expect(llm.calls == 1 && duplicates.merges.isEmpty)                         // nothing ran meanwhile
        #expect(vm.awaiting.isEmpty && vm.checkedKeys == [group.key])
        #expect(vm.proposals[group.key]?.map(\.expressionIDs) == [[pick1.id, pick3.id]])

        vm.mergeAllDuplicates()
        try await wait { vm.mergeAll == nil }
        #expect(vm.merged == 1 && vm.groups.isEmpty)                                 // the other "pick on" is apart
        #expect(Set(try await expressions.all().map(\.id)) == [pick1.id, pick2.id])
    }

    /// A group being merged isn't put to the model: the answer would be about phrases that are going.
    /// It stays unchecked as the merge leaves it, for "Check the rest". (Asked about anyway, it got an
    /// answer naming a deleted phrase: a "Merge" and a "Merge all duplicates (1)" that did nothing.)
    @Test func aGroupBeingMergedIsntPutToTheModel() async throws {
        let pick1 = phrase("pick on sb", "придираться", 0), pick2 = phrase("pick on someone", "дразнить", 1)
        let pick3 = phrase("to pick on smb", "придираться", 2)
        let llm = SlowLLM()
        let (vm, _, _) = sheet([pick1, pick2, pick3] + twoMeanings(1), llm: llm)
        vm.start()
        try await wait { vm.phase != .scanning }
        let group = try #require(vm.groups.first { $0.expressions.count == 3 })

        vm.mergeGroup(group)                    // the exact pair is being merged…
        vm.startCheck()                         // …so the Check takes the other group only
        #expect(vm.awaiting.count == 1 && !vm.awaiting.contains(group.key) && vm.check.total == 1)
        try await wait { vm.phase != .checking && vm.busy.isEmpty }
        #expect(vm.merged == 1 && llm.calls == 1)
        #expect(vm.groups.first { $0.key == group.key }?.expressions.map(\.id) == [pick1.id, pick2.id])
        #expect(vm.proposals[group.key] == [] && vm.duplicateMerges.isEmpty)
        #expect(!vm.checkedKeys.contains(group.key) && vm.notAsked.map(\.key) == [group.key])   // "Check the rest (1)"
    }

    // MARK: The line to the model

    /// Every group's own Check goes through the sheet's ONE line: twelve taps are three requests (five
    /// groups each), never more than three out — as "Check" sends them — with the Check's progress and
    /// Stop. (They were twelve requests at once, one group each.)
    @Test func theGroupsOwnChecksShareOneLine() async throws {
        let llm = SlowLLM()
        let (vm, _, _) = sheet(twoMeanings(12), llm: llm)
        vm.start()
        try await wait { vm.phase != .scanning }
        #expect(vm.groups.count == 12 && vm.unchecked.count == 12)

        for group in vm.groups { vm.checkGroup(group) }
        vm.checkGroup(vm.groups[0])                                                  // tapped again: already there
        #expect(vm.phase == .checking && vm.isBusy)                                  // Stop, and the progress
        #expect(vm.awaiting.count == 12 && vm.check.total == 12 && vm.check.sent == 0)
        #expect(llm.calls == 0)                                                      // a moment for the next tap
        try await wait { llm.calls == 3 }
        #expect(vm.check.sent == 12)
        try await wait { vm.phase != .checking }
        #expect(vm.phase == .checked && vm.checkedKeys.count == 12 && vm.awaiting.isEmpty)
        #expect(llm.sizes.sorted() == [2, 5, 5] && llm.mostAtOnce == 3)
        #expect(vm.check.answered == 12 && vm.check.failed == 0)
    }

    /// More than fits at once waits on the line: 20 groups are 4 requests, three out, the fourth when
    /// one comes back. A group whose own Check is tapped meanwhile joins the same run — ahead of the
    /// groups "Check" left waiting (the user asked about this one), behind the ones tapped before it.
    @Test func theLineKeepsThreeRequestsOut() async throws {
        let pick1 = phrase("pick on sb", "придираться", 100), pick2 = phrase("pick on someone", "дразнить", 101)
        let pick3 = phrase("to pick on smb", "придираться", 102)
        let llm = SlowLLM(held: true)
        let (vm, _, _) = sheet(twoMeanings(20) + [pick1, pick2, pick3], llm: llm)
        vm.start()
        try await wait { vm.phase != .scanning }
        let pick = try #require(vm.groups.first { $0.expressions.count == 3 })
        vm.mergeGroup(pick)                                                          // being merged: "Check" leaves it out
        vm.startCheck()
        try await wait { llm.calls == 3 && vm.busy.isEmpty }
        #expect(vm.check.sent == 15 && vm.check.total == 20)

        let rest = try #require(vm.groups.first { $0.key == pick.key })              // as the merge left it
        vm.checkGroup(rest)                                                          // while three are out
        #expect(vm.check.total == 21 && vm.awaiting.count == 21)
        try await Task.sleep(for: .milliseconds(60))                                 // past the moment for the next tap
        #expect(llm.calls == 3)                                                      // three are out: it waits its turn
        llm.release()
        try await wait { vm.phase != .checking }
        #expect(llm.calls == 5 && llm.mostAtOnce == 3 && llm.askedTwice == 0)
        // Ahead of the five that waited: it leads a full request, and one of them goes last, alone.
        #expect(llm.batches.contains { $0.first == pick.key && $0.count == 5 } && llm.sizes.sorted() == [1, 5, 5, 5, 5])
        #expect(vm.checkedKeys.count == 21)
    }

    /// A group's own Check, then "Check": one line — the rest join it and nobody is asked about twice.
    @Test func checkJoinsTheGroupsAlreadyOnTheLine() async throws {
        let llm = SlowLLM()
        let (vm, _, _) = sheet(twoMeanings(12), llm: llm)
        vm.start()
        try await wait { vm.phase != .scanning }
        let tapped = vm.groups.prefix(4).map(\.key)
        for group in vm.groups.prefix(4) { vm.checkGroup(group) }
        #expect(vm.notAsked.count == 8)                                              // "Check the rest (8)"
        vm.startCheck()
        #expect(vm.awaiting.count == 12 && vm.check.total == 12 && vm.notAsked.isEmpty)
        try await wait { vm.phase != .checking }
        #expect(llm.calls == 3 && llm.mostAtOnce == 3 && llm.askedTwice == 0)
        #expect(llm.batches.contains { Array($0.prefix(4)) == tapped })              // the tapped ones lead a request
        #expect(vm.checkedKeys.count == 12)
    }

    /// Stop reaches a group's own Check too: its request is cancelled, the group is free again, and
    /// nothing comes in later. "Don't merge" on a group still waiting on the line takes it off.
    @Test func stopEndsTheLine() async throws {
        let llm = SlowLLM(held: true)
        let (vm, _, _) = sheet(twoMeanings(12), llm: llm)
        vm.start()
        try await wait { vm.phase != .scanning }
        for group in vm.groups.prefix(5) { vm.checkGroup(group) }
        try await wait { llm.calls == 1 }
        vm.stop()
        #expect(vm.phase == .stopped && vm.awaiting.isEmpty && !vm.isBusy)
        try await wait { llm.cancelled == 1 }
        #expect(llm.cancelled == 1)                                                  // cancelled, not left running
        llm.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(llm.answers == 0 && vm.checkedKeys.isEmpty)                          // and nothing comes in later
        #expect(vm.unchecked.count == 12 && vm.check.sent == vm.check.answered)

        let kept = vm.groups[0]
        vm.checkGroup(vm.groups[0])
        vm.checkGroup(vm.groups[1])
        vm.keepApart(kept)                                                           // before it was sent
        #expect(vm.check.total == 1 && vm.awaiting == [vm.groups[0].key])
        try await wait { vm.phase != .checking }
        #expect(llm.sizes.last == 1 && vm.phase == .checked && vm.checkedKeys.count == 1)
    }

    /// A service that doesn't answer ends the run: the requests out are dropped, what waited on the
    /// line isn't sent, the groups are free for another try — and the reason is shown.
    @Test func aDeadServiceEndsTheLine() async throws {
        let llm = ScriptedLLM(script: Array(repeating: .failure(LLMError.overloaded), count: 100))
        let (vm, _, _) = sheet(twoMeanings(30), llm: llm)
        vm.start()
        try await wait { vm.phase != .scanning }
        vm.startCheck()
        try await wait { vm.phase != .checking }
        #expect(vm.phase == .failed && vm.errorMessage != nil)
        #expect(vm.awaiting.isEmpty && vm.checkedKeys.isEmpty && vm.notAsked.count == 30)
        #expect(llm.calls <= 6)                                                      // three requests, each asked twice
        try await Task.sleep(for: .milliseconds(50))
        #expect(llm.calls <= 6)
    }

    /// A batch without an answer stays unchecked, counted, and the line goes on with the rest.
    @Test func aBatchWithoutAnAnswerStaysUnchecked() async throws {
        let all = twoMeanings(12)
        let (vm, _, _) = sheet(all, llm: RejectingLLM(rejected: ["word 0"]))        // its batch: groups 0–4
        vm.start()
        try await wait { vm.phase != .scanning }
        #expect(vm.groups.first?.key == "word 0")
        vm.startCheck()
        try await wait { vm.phase != .checking }
        #expect(vm.phase == .checked && vm.check.answered == 12 && vm.check.failed == 5)
        #expect(vm.checkedKeys.count == 7 && vm.notAsked.count == 5 && vm.awaiting.isEmpty)
    }

    /// Closing the sheet stops "Merge all" after the merge under way, and the list behind is read once
    /// that one is stored — not before, showing a card that's about to go.
    @Test func closingTheSheetWaitsForTheMergeUnderWay() async throws {
        let all = exactPairs(10)
        let expressions = MockExpressionRepository(seed: all)
        let cards = MockReviewCardRepository(seed: all.flatMap(newCards))
        let duplicates = SlowMerges(DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions, cards: cards))
        let vm = list(expressions, cards, duplicates: duplicates, scope: .studying)
        await vm.load()
        #expect(vm.expressions.count == 20)
        vm.openDuplicates()
        let session = try #require(vm.duplicatesSession)
        session.start()
        try await wait { session.phase != .scanning }
        duplicates.holdFrom = 2                                                      // the second merge is under way…
        session.mergeAllDuplicates()
        try await wait { duplicates.merges.count == 2 }

        vm.endDuplicates()                                                           // …when the sheet closes
        #expect(vm.duplicatesSession == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.expressions.count == 20)                                          // not reloaded under the merge
        duplicates.release()
        try await wait { vm.expressions.count < 20 }
        let stored = try await expressions.all().count
        #expect(stored == 18)                                                        // stopped, not run to the end
        #expect(vm.expressions.count == stored)                                      // the list shows what's stored
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await expressions.all().count == stored)
    }
}

/// The real use case with merges that take a little time — counted, how many at once, failing from the
/// `failFrom`-th on; from the `holdFrom`-th on a merge waits under way until the test lets go (`release`).
private final class SlowMerges: DuplicatesUseCase, @unchecked Sendable {
    private let inner: DuplicatesInteractor
    private let lock = NSLock()
    private var made: [String] = []
    private var running = 0, peak = 0
    private var failing: Int?
    private var holding: Int?
    /// The merges asked for, by what they join.
    var merges: [String] { lock.withLock { made } }
    var mostAtOnce: Int { lock.withLock { peak } }
    var failFrom: Int? {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    var holdFrom: Int? {
        get { lock.withLock { holding } }
        set { lock.withLock { holding = newValue } }
    }
    func release() { holdFrom = nil }

    init(_ inner: DuplicatesInteractor) { self.inner = inner }

    func merge(_ expressions: [Domain.Expression], into card: CardText, as kind: DuplicateKind,
               studiedLanguage: String, nativeLanguage: String) async throws {
        let (fails, number) = lock.withLock { () -> (Bool, Int) in
            made.append(expressions.map(\.en).joined(separator: " + "))
            running += 1
            peak = max(peak, running)
            return (failing.map { made.count > $0 } ?? false, made.count)
        }
        defer { lock.withLock { running -= 1 } }
        try await Task.sleep(for: .milliseconds(10))
        while let from = holdFrom, number >= from { try await Task.sleep(for: .milliseconds(5)) }
        if fails { throw RepositoryError.persistenceFailed("no room") }
        try await inner.merge(expressions, into: card, as: kind, studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
    }

    func scan(studiedLanguage: String, full: Bool) -> AsyncThrowingStream<DuplicateScanStep, Error> {
        inner.scan(studiedLanguage: studiedLanguage, full: full)
    }
    func check(_ groups: [DuplicateGroup], studiedLanguage: String, nativeLanguage: String) async throws
        -> [String: [DuplicateMerge]] {
        try await inner.check(groups, studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
    }
    func proposals(for expressions: [Domain.Expression], studiedLanguage: String, nativeLanguage: String) async throws
        -> [DuplicateMerge] {
        try await inner.proposals(for: expressions, studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
    }
    func lookAlikesInFlashcards(for expressions: [Domain.Expression], studiedLanguage: String) async throws
        -> [UUID: [Domain.Expression]] {
        try await inner.lookAlikesInFlashcards(for: expressions, studiedLanguage: studiedLanguage)
    }
    func mergeCaught(_ caught: Domain.Expression, into lookAlikes: [Domain.Expression],
                     studiedLanguage: String, nativeLanguage: String) async throws {
        try await inner.mergeCaught(caught, into: lookAlikes, studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
    }
    func caughtMerge(_ caught: Domain.Expression, into lookAlikes: [Domain.Expression],
                     studiedLanguage: String, nativeLanguage: String) async throws -> DuplicateMerge {
        try await inner.caughtMerge(caught, into: lookAlikes, studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
    }
    func keepApart(_ caught: UUID, from lookAlikes: [UUID]) async throws { try await inner.keepApart(caught, from: lookAlikes) }
    func markNotDuplicates(_ expressionIDs: [UUID]) async throws { try await inner.markNotDuplicates(expressionIDs) }
    func notDuplicates() async throws -> Set<NotDuplicatePair> { try await inner.notDuplicates() }
}

/// Answers like the mock, after a while — or, `held`, only once the test lets go (`release`), so a
/// test decides what happens while requests are out. Counts the requests: how many, how many at once,
/// which groups each asked about, how many were answered and how many cancelled.
private final class SlowLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [[String]] = []
    private var running = 0, peak = 0, answered = 0, dropped = 0
    private var isHeld: Bool
    init(held: Bool = false) { isHeld = held }

    var calls: Int { lock.withLock { asked.count } }
    var answers: Int { lock.withLock { answered } }
    var cancelled: Int { lock.withLock { dropped } }
    var mostAtOnce: Int { lock.withLock { peak } }
    /// The group keys of each request, in the order sent.
    var batches: [[String]] { lock.withLock { asked } }
    var sizes: [Int] { batches.map(\.count) }
    /// Groups more than one request asked about.
    var askedTwice: Int { Dictionary(grouping: batches.flatMap { $0 }, by: { $0 }).values.filter { $0.count > 1 }.count }
    func release() { lock.withLock { isHeld = false } }

    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        let waits = lock.withLock { () -> Bool in
            asked.append((input as? [DuplicateGroupItem])?.map(\.id) ?? [])
            running += 1
            peak = max(peak, running)
            return isHeld
        }
        defer { lock.withLock { running -= 1 } }
        do {
            if waits {
                while lock.withLock({ isHeld }) { try await Task.sleep(for: .milliseconds(5)) }
            } else {
                try await Task.sleep(for: .milliseconds(200))
            }
        } catch {
            lock.withLock { dropped += 1 }
            throw error
        }
        let output = try await MockLLMClient().run(template, input: input)
        lock.withLock { answered += 1 }
        return output
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
    private var count = 0
    var calls: Int { lock.withLock { count } }
    init(script: [Step]) { self.script = script }

    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        let step: Step = lock.withLock {
            count += 1
            return script.isEmpty ? .success : script.removeFirst()
        }
        switch step {
        case .success: return try await MockLLMClient().run(template, input: input)
        case .failure(let error): throw error
        }
    }
}
