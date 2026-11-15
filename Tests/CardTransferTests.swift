//
//  CardTransferTests.swift
//  EnglishHelperTests
//
//  Card files: the JSON format (lenient optional fields, both date styles, wrong / newer files),
//  importing straight into flashcards (new, from Caught, already there, repeats), export → import
//  keeping the learning progress, and a deck of thousands of cards on a real SwiftData store.
//

import Testing
import Foundation
import SwiftData
import Domain
import Adapters
import Presentation

@Suite struct CardTransferTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Format

    /// The shape tools/algoapp_to_cards.py writes: no review, optional fields omitted, a date without
    /// fractional seconds, an extra "source".
    @Test func readsAConvertedDeck() throws {
        let json = """
        {"format": "gist-it-cards", "version": 1, "exportedAt": "2026-11-08T16:34:12Z",
         "source": "AlgoApp deck ADA_phrases_set",
         "cards": [
          {"expression": "jump the gun", "translation": "поторопиться",
           "example": "Don’t jump the gun — wait for the official announcement."},
          {"expression": "Temerity", "translation": "Дерзость", "synonyms": ["audacity", "boldness"],
           "context": "→ У него хватило дерзости."}
         ]}
        """
        let file = try CardFile.decode(Data(json.utf8))
        #expect(file.cards.count == 2)
        #expect(file.cards[0].synonyms == nil && file.cards[0].review == nil)
        #expect(file.cards[1].synonyms == ["audacity", "boldness"])
        #expect(file.exportedAt != nil)
        #expect(file.source == "AlgoApp deck ADA_phrases_set")
    }

    @Test func rejectsOtherFilesAndNewerVersions() {
        #expect(throws: CardFileError.notACardFile) { try CardFile.decode(Data("not json".utf8)) }
        #expect(throws: CardFileError.notACardFile) {
            try CardFile.decode(Data(#"{"format":"anki","version":1,"cards":[]}"#.utf8))
        }
        #expect(throws: CardFileError.newerVersion(2)) {
            try CardFile.decode(Data(#"{"format":"gist-it-cards","version":2,"cards":[]}"#.utf8))
        }
    }

    @Test func encodeDecodeRoundTrip() throws {
        let card = ReviewCard(expressionID: UUID(), direction: .recall, state: .review,
                              due: now.addingTimeInterval(86_400.5), stability: 4.25, difficulty: 5.5, reps: 3,
                              lapses: 1, lastReview: now, firstReview: now.addingTimeInterval(-86_400))
        let file = CardFile(cards: [CardFile.Card(expression: "a", translation: "б", review: [CardFile.Review(card)])],
                            exportedAt: now)
        #expect(try CardFile.decode(file.encoded()) == file)
    }

    // MARK: Import / export

    private func card(_ en: String, _ ru: String = "перевод") -> CardFile.Card {
        CardFile.Card(expression: en, translation: ru)
    }

    @Test func importGoesStraightIntoFlashcards() async throws {
        let caught = Domain.Expression(en: "Break the ice", ru: "растопить лёд")
        let studied = Domain.Expression(en: "jump the gun", ru: "поторопиться")
        let expressions = MockExpressionRepository(seed: [caught, studied])
        let cards = MockReviewCardRepository(seed: CardDirection.allCases.map {
            ReviewCard(expressionID: studied.id, direction: $0, state: .review, due: now, stability: 5,
                       difficulty: 5, reps: 3, lastReview: now)
        })
        let sut = CardTransferInteractor(expressions: expressions, cards: cards)
        let file = CardFile(cards: [card("new one"), card("break the ice "), card("Jump the gun"),
                                    card("New One"), card("  ", "x"), card("no translation", "")])
        let report = try await sut.importIntoFlashcards(file, now: now)
        #expect(report == CardImportReport(added: 1, movedFromCaught: 1, alreadyInFlashcards: 1, skipped: 3))

        let all = try await expressions.all()
        #expect(all.count == 3)
        let added = try #require(all.first { $0.en == "new one" })
        let stored = try await cards.all()
        #expect(stored.filter { $0.expressionID == added.id }.map(\.state) == [.new, .new])
        #expect(stored.filter { $0.expressionID == caught.id }.count == 2)                 // moved in
        #expect(stored.filter { $0.expressionID == studied.id }.allSatisfy { $0.reps == 3 })  // untouched

        // Imported phrases are practised at once — no stop on the Caught list.
        let flashcards = FlashcardsInteractor(expressions: expressions, cards: cards)
        #expect(try await flashcards.stats(now: now).caught == 0)
    }

    /// The cards fail to store after the phrases went in: the new phrases are taken back (the file
    /// doesn't end up on Caught), what was there is untouched — and importing again completes it.
    @Test func aFailedCardWriteTakesTheNewPhrasesBack() async throws {
        let caught = Domain.Expression(en: "Break the ice", ru: "растопить лёд")
        let expressions = MockExpressionRepository(seed: [caught])
        let cards = FailingSaveAllCards(failures: 1)
        let sut = CardTransferInteractor(expressions: expressions, cards: cards)
        let file = CardFile(cards: [card("new one"), card("another"), card("break the ice")])

        await #expect(throws: RepositoryError.self) { _ = try await sut.importIntoFlashcards(file, now: now) }
        #expect(try await expressions.all().map(\.id) == [caught.id])
        #expect(try await cards.all().isEmpty)

        let report = try await sut.importIntoFlashcards(file, now: now)
        #expect(report == CardImportReport(added: 2, movedFromCaught: 1, alreadyInFlashcards: 0, skipped: 0))
        #expect(try await expressions.all().count == 3)
        #expect(try await cards.all().count == 6)
    }

    /// A phrase on Caught is moved into flashcards WHILE a file holding it is being imported (after
    /// the import looked at what's in flashcards, before it stored its cards): the phrase keeps the
    /// two cards the move gave it — not four — and the file's other phrases come in as usual.
    @Test func aMoveDuringAnImportLeavesTwoCards() async throws {
        let caught = Domain.Expression(en: "Break the ice", ru: "растопить лёд")
        let expressions = MockExpressionRepository(seed: [caught])
        let cards = RacingCards(enrollingMeanwhile: caught.id, at: now)
        let sut = CardTransferInteractor(expressions: expressions, cards: cards)
        let review = ReviewCard(expressionID: UUID(), direction: .recognition, state: .review,
                                due: now.addingTimeInterval(86_400), stability: 9, difficulty: 4, reps: 5, lastReview: now)
        let file = CardFile(cards: [
            CardFile.Card(expression: "break the ice", translation: "растопить лёд", review: [CardFile.Review(review)]),
            card("new one"),
        ])

        let report = try await sut.importIntoFlashcards(file, now: now)
        #expect(report.added == 1 && report.movedFromCaught == 1)
        let stored = try await cards.all()
        let ofCaught = stored.filter { $0.expressionID == caught.id }
        #expect(ofCaught.count == 2 && Set(ofCaught.map(\.direction)) == Set(CardDirection.allCases))
        #expect(ofCaught.allSatisfy { $0.state == .new })                 // the move's cards stay; the file's are skipped
        #expect(stored.count == 4)                                         // + the new phrase's two
    }

    /// The store's all-in-one-step insert: a card is stored unless its expression already has one of
    /// that direction (also inside one batch); what is there keeps its progress.
    @Test func addMissingKeepsOneCardPerDirection() async throws {
        let container = try ModelContainer(for: ReviewCardModel.self, ReviewLogModel.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let stores: [any ReviewCardRepository] = [MockReviewCardRepository(),
                                                  SwiftDataReviewCardRepository(modelContainer: container)]
        for store in stores {
            let a = UUID(), b = UUID()
            let known = ReviewCard(expressionID: a, direction: .recognition, state: .review, due: now, stability: 12,
                                   difficulty: 4, reps: 7, lastReview: now)
            try await store.save(known)
            try await store.addMissing([
                ReviewCard(expressionID: a, direction: .recognition, due: now),      // taken → skipped
                ReviewCard(expressionID: a, direction: .recall, due: now),
                ReviewCard(expressionID: b, direction: .recall, due: now),
                ReviewCard(expressionID: b, direction: .recall, due: now),           // twice in one batch → once
            ])
            let stored = try await store.all()
            #expect(stored.count == 3)
            #expect(stored.first { $0.expressionID == a && $0.direction == .recognition } == known)
            #expect(stored.filter { $0.expressionID == b }.map(\.direction) == [.recall])

            // Many expressions at once (the import's path: one read of the deck).
            let many = (0..<60).flatMap { _ -> [ReviewCard] in
                let id = UUID()
                return CardDirection.allCases.map { ReviewCard(expressionID: id, direction: $0, due: now) }
            }
            try await store.addMissing(many + [ReviewCard(expressionID: a, direction: .recall, due: now)])
            #expect(try await store.all().count == 3 + 120)
        }
    }

    /// The "not duplicates" links fail to store: the cards are in, so the import succeeded.
    @Test func failedLinksDoNotFailTheImport() async throws {
        let expressions = MockExpressionRepository(seed: [])
        let cards = MockReviewCardRepository()
        let sut = CardTransferInteractor(expressions: expressions, cards: cards, marks: FailingMarks())
        let file = CardFile(cards: [
            CardFile.Card(expression: "solid", translation: "надёжный", notDuplicateOf: ["a solid"]),
            CardFile.Card(expression: "a solid", translation: "твёрдое тело", notDuplicateOf: ["solid"]),
        ])
        let report = try await sut.importIntoFlashcards(file, now: now)
        #expect(report.added == 2)
        #expect(try await cards.all().count == 4)
    }

    /// Export → import on another (empty) app keeps every field and the learning progress.
    @Test func exportThenImportKeepsProgress() async throws {
        let e = Domain.Expression(en: "jump the gun", ru: "поторопиться", example: "Don't jump the gun.",
                                  synonyms: ["rush"], context: "idiom")
        let review = ReviewCard(expressionID: e.id, direction: .recognition, state: .review,
                                due: now.addingTimeInterval(10 * 86_400), stability: 9.5, difficulty: 4.2,
                                reps: 6, lapses: 1, lastReview: now, firstReview: now.addingTimeInterval(-20 * 86_400))
        let source = CardTransferInteractor(
            expressions: MockExpressionRepository(seed: [e, Domain.Expression(en: "caught only", ru: "x")]),
            cards: MockReviewCardRepository(seed: [review]))
        let file = try CardFile.decode(try await source.exportFlashcards(now: now).encoded())
        #expect(file.cards.map(\.expression) == ["jump the gun"])                     // flashcards only

        let expressions = MockExpressionRepository(seed: [])
        let cards = MockReviewCardRepository()
        let report = try await CardTransferInteractor(expressions: expressions, cards: cards)
            .importIntoFlashcards(file, now: now)
        #expect(report.added == 1)
        let imported = try #require(try await expressions.all().first)
        #expect(imported.example == "Don't jump the gun." && imported.synonyms == ["rush"] && imported.context == "idiom")
        let restored = try await cards.all()
        let recognition = try #require(restored.first { $0.direction == .recognition })
        #expect(recognition.state == .review && recognition.reps == 6 && recognition.lapses == 1)
        #expect(abs(recognition.stability - 9.5) < 1e-9)
        #expect(restored.first { $0.direction == .recall }?.state == .new)            // missing direction → new
    }

    /// A deck the size of a real one (10,000 cards) on an on-disk SwiftData store: the import is two
    /// batches, and the dashboard / queue stay usable afterwards.
    @Test func thousandsOfCardsOnARealStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deck-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = PersistenceSchema.current
        let container = try ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self,
                                           configurations: ModelConfiguration(schema: schema, url: dir.appending(path: "s.store")))
        let expressions = SwiftDataExpressionRepository(modelContainer: container)
        let cards = SwiftDataReviewCardRepository(modelContainer: container)
        let file = CardFile(cards: (0..<10_000).map {
            CardFile.Card(expression: "phrase \($0)", translation: "фраза \($0)", example: "An example \($0).",
                          synonyms: ["a", "b"])
        })

        let clock = ContinuousClock()
        let importTime = try await clock.measure {
            let report = try await CardTransferInteractor(expressions: expressions, cards: cards)
                .importIntoFlashcards(file, now: now)
            #expect(report.added == 10_000)
        }
        let flashcards = FlashcardsInteractor(expressions: expressions, cards: cards)
        var stats: StudyStats?
        let statsTime = try await clock.measure { stats = try await flashcards.stats(now: now) }
        #expect(stats?.inStudy == 10_000)
        #expect(stats?.today.nextSet == StageCounts(new: DailyGoalOptions.default))
        #expect(stats?.distribution.new == 20_000)
        let queue = try await flashcards.queue(now: now)
        #expect(queue.count == DailyGoalOptions.default)
        #expect(queue.allSatisfy { $0.card.direction == .recognition && $0.card.state == .new })
        print("10k import: \(importTime), stats: \(statsTime)")
        #expect(importTime < .seconds(30))
        #expect(statsTime < .seconds(5))
    }
}

@Suite @MainActor struct CardTransferViewModelTests {
    @Test func importFromTheListReportsAndReloads() async throws {
        let repo = MockExpressionRepository(seed: [])
        let cards = MockReviewCardRepository()
        let vm = StudyListViewModel(
            studyList: StudyListInteractor(repository: repo, cards: cards),
            saveExpression: SaveExpressionInteractor(enrich: EnrichExpressionInteractor(llm: MockLLMClient()),
                                                     repository: repo),
            exportAlgoApp: ExportDeckInteractor(repository: repo, exporter: AlgoAppXMLExporter()),
            exportAnki: ExportDeckInteractor(repository: repo, exporter: AnkiExporter()),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            isConfigured: true,
            flashcards: FlashcardsInteractor(expressions: repo, cards: cards),
            cardTransfer: CardTransferInteractor(expressions: repo, cards: cards),
            scope: .studying
        )
        #expect(vm.canTransferCards)
        let data = try CardFile(cards: [CardFile.Card(expression: "a", translation: "б"),
                                        CardFile.Card(expression: "c", translation: "д")]).encoded()
        vm.importCards(data)
        #expect(vm.isImporting)
        var tries = 0
        while vm.isImporting, tries < 200 { tries += 1; try await Task.sleep(for: .milliseconds(10)) }
        #expect(vm.expressions.count == 2)
        #expect(vm.importMessage?.contains("2") == true)

        vm.clearImportMessage()
        vm.importCards(Data("nope".utf8))
        tries = 0
        while vm.isImporting, tries < 200 { tries += 1; try await Task.sleep(for: .milliseconds(10)) }
        #expect(vm.importMessage != nil)
        #expect(vm.expressions.count == 2)

        vm.exportCards()
        tries = 0
        while vm.exportedDeck == nil, tries < 200 { tries += 1; try await Task.sleep(for: .milliseconds(10)) }
        let deck = try #require(vm.exportedDeck)
        #expect(deck.filename.hasSuffix(".json"))
        #expect(try CardFile.decode(deck.data).cards.count == 2)
    }
}

/// Cards whose batch insert fails the first `failures` times, storing nothing.
private actor FailingSaveAllCards: ReviewCardRepository {
    private let inner = MockReviewCardRepository()
    private var failures: Int
    init(failures: Int) { self.failures = failures }

    func all() async throws -> [ReviewCard] { try await inner.all() }
    func save(_ card: ReviewCard) async throws { try await inner.save(card) }
    func saveAll(_ cards: [ReviewCard]) async throws { try await inner.saveAll(cards) }
    func delete(expressionID: UUID) async throws { try await inner.delete(expressionID: expressionID) }
    func addMissing(_ cards: [ReviewCard]) async throws {
        if failures > 0 {
            failures -= 1
            throw RepositoryError.persistenceFailed("disk full")
        }
        try await inner.addMissing(cards)
    }
    func replaceCards(of expressionIDs: Set<UUID>, with cards: [ReviewCard]) async throws {
        try await inner.replaceCards(of: expressionIDs, with: cards)
    }
    func appendLog(_ log: ReviewLog) async throws { try await inner.appendLog(log) }
    func logs(since date: Date) async throws -> [ReviewLog] { try await inner.logs(since: date) }
}

/// "Not duplicates" links that can't be stored.
private struct FailingMarks: NotDuplicateMarking {
    func pairs() async throws -> Set<NotDuplicatePair> { [] }
    func mark(_ pairs: Set<NotDuplicatePair>) async throws { throw RepositoryError.persistenceFailed("disk full") }
    func unmark(involving ids: Set<UUID>) async throws {}
}

/// Cards where a move from Caught lands in the middle of an import: right before the import's cards
/// are stored, `enrollingMeanwhile` gets its two new cards — as `FlashcardsInteractor.enroll` gives them.
private actor RacingCards: ReviewCardRepository {
    private let inner = MockReviewCardRepository()
    private let expressionID: UUID
    private let date: Date
    private var raced = false

    init(enrollingMeanwhile expressionID: UUID, at date: Date) {
        self.expressionID = expressionID
        self.date = date
    }

    func all() async throws -> [ReviewCard] { try await inner.all() }
    func save(_ card: ReviewCard) async throws { try await inner.save(card) }
    func saveAll(_ cards: [ReviewCard]) async throws {
        try await race()                                    // whichever way the import writes its cards
        try await inner.saveAll(cards)
    }
    func delete(expressionID: UUID) async throws { try await inner.delete(expressionID: expressionID) }
    func addMissing(_ cards: [ReviewCard]) async throws {
        try await race()
        try await inner.addMissing(cards)
    }

    /// The move from Caught lands now — once.
    private func race() async throws {
        guard !raced else { return }
        raced = true
        try await inner.addMissing(CardDirection.allCases.map {
            ReviewCard(expressionID: expressionID, direction: $0, due: date)
        })
    }
    func replaceCards(of expressionIDs: Set<UUID>, with cards: [ReviewCard]) async throws {
        try await inner.replaceCards(of: expressionIDs, with: cards)
    }
    func appendLog(_ log: ReviewLog) async throws { try await inner.appendLog(log) }
    func logs(since date: Date) async throws -> [ReviewLog] { try await inner.logs(since: date) }
}
