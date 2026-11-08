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
        #expect(stats?.today.new == FlashcardsInteractor.defaultNewCardsPerDay)
        #expect(stats?.distribution.new == 20_000)
        let queue = try await flashcards.queue(now: now)
        #expect(queue.first?.expression.en == "phrase 0")                          // file order
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
