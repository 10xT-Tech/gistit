//
//  CatchCardsTests.swift
//  EnglishHelperTests
//
//  Caught: cards from photos (template decoding, the per-photo batch with progress, duplicates,
//  failures that skip a photo vs ones that stop the batch, the progress sheet), the four-line card
//  text, moving everything into flashcards, and the In-flashcards scope.
//

import Testing
import Foundation
import Domain
import Adapters
import Presentation

@Suite @MainActor struct CatchCardsTests {

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while !condition() {
            if clock.now - start > timeout { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func image(_ tag: UInt8) -> RecognizableImage { RecognizableImage(data: Data([tag])) }

    // MARK: Template

    @Test func photoCardsDecodeCleansAndCapsSynonyms() throws {
        let raw = #"""
        {"cards":[
          {"expression":" **threshold** ","translation":"порог / граница","example":"the value exceeds the threshold.",
           "synonyms":["limit","boundary","cutoff","edge",""],"context":" **нейтрально** "},
          {"expression":"  ","translation":"x","example":"y","synonyms":[],"context":""},
          {"expression":"discard","translation":"отбросить","example":"z","synonyms":[]}
        ]}
        """#
        let result = try PhotoCardsTemplate().decode(raw)
        #expect(result.cards.count == 2)                          // the blank expression is dropped
        #expect(result.cards[0].expression == "threshold")
        #expect(result.cards[0].synonyms == ["limit", "boundary", "cutoff"])
        #expect(result.cards[0].context == "нейтрально")
        #expect(result.cards[1].context.isEmpty)                  // no note: still a card
    }

    @Test func photoCardsPromptNamesTheLanguages() {
        let prompt = PhotoCardsTemplate(studiedLanguage: "German", nativeLanguage: "French").systemPrompt
        #expect(prompt.contains("German vocabulary card generator for a French speaker"))
    }

    /// What's meant to be learned only: a post's featured phrase, whole, with the translation it shows;
    /// on a page, the phrases the reader marked (dictionary form, their sentence as the example); never
    /// unmarked running text or the app around the content.
    @Test func photoCardsPromptCardsOnlyWhatsMeantToBeLearned() {
        let template = PhotoCardsTemplate()
        #expect(template.systemPrompt.contains("make ONE card for that phrase, whole"))
        #expect(template.systemPrompt.contains("never split it into words or parts"))
        #expect(template.systemPrompt.contains("make one such card for each of them"))   // a list of phrases
        #expect(template.systemPrompt.contains("highlighted with a marker, underlined, circled"))
        #expect(template.systemPrompt.contains("unmarked running text gives no cards"))
        #expect(template.systemPrompt.contains("the sentence it stands in on the page"))
        #expect(template.systemPrompt.contains("song and music titles"))
        #expect(template.systemPrompt.contains("\"context\""))                         // a usage note on every card
        #expect(template.outputJSONSchema.contains("\"required\":[\"expression\",\"translation\",\"example\",\"synonyms\",\"context\"]"))
        #expect(!template.systemPrompt.contains("do not skip anything"))
        #expect(template.userMessage(for: RecognizableImage(data: Data())).contains("the phrases marked on it"))
    }

    /// Caught cards get the letter case Fix cards writes, whatever the model returned.
    @Test func caughtCardsGetTheLetterCase() async throws {
        let repo = MockExpressionRepository(seed: [])
        let sut = CatchCardsFromPhotosInteractor(llm: ShoutingLLM(), repository: repo)
        for try await _ in sut([RecognizableImage(data: Data([1]))], studiedLanguage: "English", nativeLanguage: "Russian") {}
        let card = try #require(try await repo.all().first)
        #expect(card.en == "I'm on the fence" && card.ru == "я сомневаюсь")
        #expect(card.example == "I'm on the fence about it." && card.synonyms == ["I can't decide"])
        #expect(card.context == "нейтрально")
    }

    /// A photo with nothing featured or marked gives no cards — and is counted, so the sheet can say
    /// to mark the phrases.
    @Test func aPhotoWithNothingMarkedIsCounted() async throws {
        let sut = CatchCardsFromPhotosInteractor(llm: NothingMarkedLLM(), repository: MockExpressionRepository(seed: []))
        var last: CatchProgress?
        for try await step in sut([RecognizableImage(data: Data([1])), RecognizableImage(data: Data([2]))],
                                  studiedLanguage: "English", nativeLanguage: "Russian") { last = step }
        #expect(last == CatchProgress(processed: 2, total: 2, added: 0, failed: 0, empty: 2))
    }

    // MARK: Batch

    /// Two photos: progress after each, cards stored, a card already saved (or repeated) is skipped.
    @Test func eachPhotoBecomesCardsWithProgress() async throws {
        let repo = MockExpressionRepository(seed: [Domain.Expression(en: "Discard", ru: "отбросить")])
        let sut = CatchCardsFromPhotosInteractor(llm: MockLLMClient(), repository: repo)
        var steps: [CatchProgress] = []
        for try await step in sut([image(1), image(2)], studiedLanguage: "English", nativeLanguage: "Russian") {
            steps.append(step)
        }
        #expect(steps.map(\.processed) == [0, 1, 2])
        #expect(steps.last == CatchProgress(processed: 2, total: 2, added: 1, failed: 0))
        let stored = try await repo.all().map(\.en)
        #expect(stored.sorted() == ["Discard", "threshold"])     // "discard" matched the saved "Discard"
        let card = try #require(try await repo.all().first { $0.en == "threshold" })
        #expect(card.ru == "порог / граница")
        #expect(card.synonyms == ["limit", "boundary", "cutoff"])
        #expect(card.context == "нейтрально; о пределе значения.")      // the usage note is stored
    }

    /// A photo the model answers badly is skipped; the free plan's limit stops the batch (cards so far stay).
    @Test func badPhotoIsSkippedButTheLimitStops() async throws {
        let repo = MockExpressionRepository(seed: [])
        let llm = ScriptedPhotoLLM(script: [.failure(LLMError.invalidOutput("x")), .success,
                                            .failure(LLMError.subscriptionRequired(retryAfter: 120)), .success])
        let sut = CatchCardsFromPhotosInteractor(llm: llm, repository: repo)
        var last: CatchProgress?
        var stoppedBy: Error?
        do {
            for try await step in sut([image(1), image(2), image(3), image(4)],
                                      studiedLanguage: "English", nativeLanguage: "Russian") {
                last = step
            }
        } catch {
            stoppedBy = error
        }
        #expect(last == CatchProgress(processed: 2, total: 4, added: 2, failed: 1))
        guard case LLMError.subscriptionRequired? = stoppedBy as? LLMError else {
            Issue.record("expected the plan limit to stop the batch, got \(String(describing: stoppedBy))")
            return
        }
        #expect(try await repo.all().count == 2)
    }

    @Test func progressSheetRunsToDone() async throws {
        let repo = MockExpressionRepository(seed: [])
        let vm = CatchFromPhotosViewModel(photoCount: 3,
                                          catchCards: CatchCardsFromPhotosInteractor(llm: MockLLMClient(), repository: repo),
                                          studiedLanguage: { "English" }, nativeLanguage: { "Russian" })
        #expect(vm.phase == .preparing)
        vm.run([Data([1]), nil, Data([2])])                       // the middle photo couldn't be loaded
        try await waitUntil { vm.phase == .done }
        #expect(vm.progress == CatchProgress(processed: 3, total: 3, added: 2, failed: 1))
        #expect(vm.progress.fraction == 1)
    }

    @Test func progressSheetOffersTheSubscriptionAtTheLimit() async throws {
        let llm = ScriptedPhotoLLM(script: [.failure(LLMError.subscriptionRequired(retryAfter: nil))])
        let vm = CatchFromPhotosViewModel(photoCount: 1,
                                          catchCards: CatchCardsFromPhotosInteractor(llm: llm, repository: MockExpressionRepository(seed: [])),
                                          studiedLanguage: { "English" }, nativeLanguage: { "Russian" })
        vm.run([Data([1])])
        try await waitUntil { vm.phase == .failed }
        #expect(vm.needsSubscription)
        #expect(vm.errorMessage != nil)
    }

    // MARK: Cards as text

    @Test func cardTextIsFourLinesAndCardsAreSeparated() {
        let a = Domain.Expression(en: "threshold", ru: "порог / граница", example: "it exceeds the threshold.",
                                  synonyms: ["limit", "boundary"])
        let b = Domain.Expression(en: "discard", ru: "отбросить")
        #expect(a.cardText == "threshold\nпорог / граница\nit exceeds the threshold.\nlimit / boundary")
        #expect(Domain.Expression.cardsText([a, b]) == a.cardText + "\n---\n" + "discard\nотбросить")
    }

    // MARK: Search

    @Test func searchLooksInEveryField() {
        let card = Domain.Expression(en: "Break the ice", ru: "растопить лёд", example: "A joke to break the ice.",
                                     synonyms: ["warm up"], context: "Неформально, в начале встречи.")
        #expect(card.matches("ICE"))                                   // case
        #expect(card.matches("лед"))                                   // ё / е
        #expect(card.matches("joke"))                                  // example
        #expect(card.matches("warm"))                                  // synonyms
        #expect(card.matches("встречи"))                               // note
        #expect(!card.matches("tomorrow"))
        #expect(card.matches("  "))                                    // empty query: everything
        #expect(Domain.Expression(en: "café", ru: "кафе").matches("cafe"))   // diacritics
    }

    @Test func listFiltersBySearch() async throws {
        let repo = MockExpressionRepository(seed: MockExpressionRepository.defaultSeed)
        let caught = makeList(repo, MockReviewCardRepository(), scope: .caught)
        await caught.load()
        #expect(caught.visibleExpressions.count == 2 && !caught.isSearching)
        caught.searchText = "благодарность"                           // the note of "I appreciate it"
        #expect(caught.isSearching)
        #expect(caught.visibleExpressions.map(\.en) == ["I appreciate it"])
        caught.searchText = "nothing like this"
        #expect(caught.visibleExpressions.isEmpty)
        #expect(caught.expressions.count == 2)                         // the list itself is intact
    }

    // MARK: Lists

    private func makeList(_ repo: MockExpressionRepository, _ cards: MockReviewCardRepository,
                          scope: StudyListViewModel.Scope) -> StudyListViewModel {
        StudyListViewModel(
            studyList: StudyListInteractor(repository: repo, cards: cards),
            saveExpression: SaveExpressionInteractor(enrich: EnrichExpressionInteractor(llm: MockLLMClient()),
                                                     repository: repo),
            exportAlgoApp: ExportDeckInteractor(repository: repo, exporter: AlgoAppXMLExporter()),
            exportAnki: ExportDeckInteractor(repository: repo, exporter: AnkiExporter()),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            isConfigured: true,
            flashcards: FlashcardsInteractor(expressions: repo, cards: cards),
            catchFromPhotos: CatchCardsFromPhotosInteractor(llm: MockLLMClient(), repository: repo),
            scope: scope
        )
    }

    /// Move all: Caught empties at once, every phrase gets its cards, and In flashcards shows them —
    /// where deleting one also deletes its cards.
    @Test func moveAllEmptiesCaughtAndFillsInFlashcards() async throws {
        let repo = MockExpressionRepository(seed: MockExpressionRepository.defaultSeed)
        let cards = MockReviewCardRepository()
        let caught = makeList(repo, cards, scope: .caught)
        let studying = makeList(repo, cards, scope: .studying)
        await caught.load()
        #expect(caught.expressions.count == 2)
        #expect(caught.canMoveToFlashcards && caught.canCatchFromPhotos)
        #expect(!studying.canMoveToFlashcards && !studying.canCatchFromPhotos)

        caught.moveAllToFlashcards()
        #expect(caught.expressions.isEmpty)
        #expect(caught.phase == .empty)
        var tries = 0
        while try await cards.all().count < 4, tries < 200 { tries += 1; try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await cards.all().count == 4)

        await studying.load()
        #expect(studying.expressions.count == 2)
        let victim = try #require(studying.expressions.first)
        // Each phrase shows its two cards, recognition first; Caught shows none.
        #expect(studying.cards(for: victim).map(\.direction) == [.recognition, .recall])
        #expect(studying.cards(for: victim).allSatisfy { $0.stage == .new && $0.reps == 0 })
        #expect(caught.cards(for: victim).isEmpty)
        studying.delete(victim)
        tries = 0
        while try await cards.all().count > 2, tries < 200 { tries += 1; try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await cards.all().allSatisfy { $0.expressionID != victim.id })
        #expect(!(try await repo.all().contains { $0.id == victim.id }))
    }

    @Test func catchSessionOpensOnceAndReloadsOnClose() async throws {
        let repo = MockExpressionRepository(seed: [])
        let caught = makeList(repo, MockReviewCardRepository(), scope: .caught)
        await caught.load()
        let session = try #require(caught.startCatch(photoCount: 2))
        #expect(caught.startCatch(photoCount: 1) == nil)          // one sheet at a time
        session.run([Data([1]), Data([2])])
        try await waitUntil { session.phase == .done }
        caught.endCatch()
        try await waitUntil { caught.expressions.count == 2 }
        #expect(caught.expressions.map(\.en).sorted() == ["discard", "threshold"])
    }
}

/// Answers photo after photo from a script: the mock's canned cards, or an error.
private final class ScriptedPhotoLLM: LLMClient, @unchecked Sendable {
    enum Step { case success, failure(Error) }
    private var script: [Step]
    private let lock = NSLock()
    init(script: [Step]) { self.script = script }

    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        let step: Step = lock.withLock { script.isEmpty ? .success : script.removeFirst() }
        switch step {
        case .success:
            // A distinct pair of cards per call, so successes add up.
            let n = UUID().uuidString.prefix(6)
            return try template.decode(#"{"cards":[{"expression":"a\#(n)","translation":"x","example":"y","synonyms":[]},{"expression":"b\#(n)","translation":"x","example":"y","synonyms":[]}]}"#)
        case .failure(let error):
            throw error
        }
    }
}

/// A page with nothing marked: the model returns no cards.
private struct NothingMarkedLLM: LLMClient {
    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        try template.decode(#"{"cards":[]}"#)
    }
}

/// Answers with the letter case all wrong.
private struct ShoutingLLM: LLMClient {
    func run<Template: PromptTemplate>(_ template: Template, input: Template.Input) async throws -> Template.Output {
        try template.decode(#"{"cards":[{"expression":"i'm On The Fence","translation":"Я Сомневаюсь","example":"i'm on the fence about it.","synonyms":["i can't Decide"],"context":"Нейтрально"}]}"#)
    }
}
