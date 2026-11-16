//
//  DeckCacheTests.swift
//  EnglishHelperTests
//
//  The expression and review-card repositories keep the deck in memory after the first read
//  (reading it from SwiftData costs about a second on a 10k-phrase deck). The copy must always say
//  what the store says: after EVERY kind of write, `all()` from the repository that made it equals
//  `all()` from a fresh repository reading the same store. And what the copy takes is reported
//  (Settings).
//

import Testing
import Foundation
import SwiftData
import Domain
import Adapters

@Suite struct DeckCacheTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: PersistenceSchema.current, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func phrase(_ en: String, _ minute: Double) -> Domain.Expression {
        Domain.Expression(en: en, ru: "перевод " + en, example: "an example with \(en).", synonyms: ["one", "two"],
                          context: "разговорное.", createdAt: now.addingTimeInterval(minute * 60))
    }

    /// The repository's answer and the store's (read by a fresh instance), which must be the same —
    /// in the same order.
    private func inStep(_ repo: SwiftDataExpressionRepository, _ container: ModelContainer,
                        _ step: String) async throws -> [Domain.Expression] {
        let cached = try await repo.all()
        let stored = try await SwiftDataExpressionRepository(modelContainer: container).all()
        #expect(cached == stored, "expressions out of step after: \(step)")
        return cached
    }

    @Test func expressionsStayInStepWithTheStore() async throws {
        let container = try container()
        let repo = SwiftDataExpressionRepository(modelContainer: container)
        let a = phrase("alpha", 0), b = phrase("bravo", 1), c = phrase("charlie", 2), d = phrase("delta", 3)

        try await repo.add(a)                                   // written before the first read
        #expect(try await inStep(repo, container, "add before a read").map(\.id) == [a.id])

        try await repo.add(c)
        try await repo.addAll([d, b])
        let newestFirst: [UUID] = [d.id, c.id, b.id, a.id]
        #expect(try await inStep(repo, container, "add, addAll").map(\.id) == newestFirst)

        var changed = b
        changed.ru = "новый перевод"
        changed.synonyms = ["three"]
        try await repo.update(changed)
        #expect(try await inStep(repo, container, "update").first { $0.id == b.id } == changed)

        try await repo.setLearned(true, id: c.id)
        #expect(try await inStep(repo, container, "setLearned").first { $0.id == c.id }?.learned == true)

        #expect(try await repo.find(en: "  ALPHA ")?.id == a.id)
        let twin = phrase("Alpha", 5)                           // the same phrase saved later: the original wins
        try await repo.add(twin)
        #expect(try await repo.find(en: "alpha")?.id == a.id)

        try await repo.delete(id: twin.id)
        try await repo.delete(id: UUID())                       // not there: nothing happens
        try await repo.deleteAll(ids: [a.id, d.id])
        let left: [UUID] = [c.id, b.id]
        #expect(try await inStep(repo, container, "delete, deleteAll").map(\.id) == left)

        await #expect(throws: RepositoryError.notFound) { try await repo.update(a) }   // gone: refused…
        _ = try await inStep(repo, container, "a refused update")                      // …and nothing changed
    }

    private func card(_ expression: UUID, _ direction: CardDirection, reps: Int = 0) -> ReviewCard {
        ReviewCard(expressionID: expression, direction: direction, state: reps == 0 ? .new : .review, due: now,
                   stability: Double(reps), difficulty: 5, reps: reps, lastReview: reps == 0 ? nil : now)
    }

    private func inStep(_ repo: SwiftDataReviewCardRepository, _ container: ModelContainer,
                        _ step: String) async throws -> Set<ReviewCard> {
        let cached = try await repo.all()
        let stored = try await SwiftDataReviewCardRepository(modelContainer: container).all()
        #expect(cached.count == stored.count && Set(cached) == Set(stored), "cards out of step after: \(step)")
        return Set(cached)
    }

    @Test func cardsStayInStepWithTheStore() async throws {
        let container = try container()
        let repo = SwiftDataReviewCardRepository(modelContainer: container)
        let a = UUID(), b = UUID(), c = UUID()
        let a1 = card(a, .recognition), a2 = card(a, .recall)

        try await repo.save(a1)                                 // written before the first read
        #expect(try await inStep(repo, container, "save before a read") == [a1])

        try await repo.saveAll([a2, card(b, .recognition), card(b, .recall)])
        #expect(try await inStep(repo, container, "saveAll").count == 4)

        // An answer: the same card, rescheduled. The row keeps its expression whatever the value says.
        let answered = ReviewCard(id: a1.id, expressionID: c, direction: .recognition, state: .review, due: now,
                                  stability: 9, difficulty: 4, reps: 1, lastReview: now)
        try await repo.save(answered)
        let afterAnswer = try await inStep(repo, container, "save (an answer)")
        let stored = try #require(afterAnswer.first { $0.id == a1.id })
        #expect(stored.reps == 1 && stored.expressionID == a)

        try await repo.addMissing([card(a, .recall), card(c, .recognition), card(c, .recall)])   // a's is taken
        #expect(try await inStep(repo, container, "addMissing").filter { $0.expressionID == c }.count == 2)
        try await repo.addMissing([card(c, .recall)])           // nothing to add: nothing written
        #expect(try await inStep(repo, container, "addMissing (nothing)").count == 6)

        // A merge: b's recognition card moves to a (replacing a's), a's recall stays, b loses its cards.
        let bRecognition = try #require(afterAnswer.first { $0.expressionID == b && $0.direction == .recognition })
        let moved = ReviewCard(id: bRecognition.id, expressionID: a, direction: .recognition, state: .review, due: now,
                               stability: 30, difficulty: 4, reps: 7, lastReview: now)
        try await repo.replaceCards(of: [a, b], with: [moved, a2])
        let merged = try await inStep(repo, container, "replaceCards")
        let ofA = Set(merged.filter { $0.expressionID == a }.map(\.id))
        let expectedOfA: Set<UUID> = [moved.id, a2.id]
        #expect(ofA == expectedOfA)
        let ofB = merged.filter { $0.expressionID == b }
        #expect(ofB.isEmpty)
        #expect(merged.count == 4)

        try await repo.delete(expressionID: c)
        try await repo.delete(expressionID: UUID())             // no cards: nothing happens
        #expect(try await inStep(repo, container, "delete").count == 2)
    }

    /// The read happens once: on a store the size of a real deck, the dashboard's numbers come back
    /// at once the second time, and stay right after an answer.
    @Test func theDeckIsReadOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deckcache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = PersistenceSchema.current
        let container = try ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self,
                                           configurations: ModelConfiguration(schema: schema, url: dir.appending(path: "s.store")))
        let phrases = (0..<5_000).map { phrase("phrase \($0)", -Double($0)) }
        // Written by one pair of repositories, read by another: nothing is in memory yet.
        try await SwiftDataExpressionRepository(modelContainer: container).addAll(phrases)
        try await SwiftDataReviewCardRepository(modelContainer: container)
            .addMissing(phrases.flatMap { p in CardDirection.allCases.map { card(p.id, $0) } })

        let expressions = SwiftDataExpressionRepository(modelContainer: container)
        let cards = SwiftDataReviewCardRepository(modelContainer: container)
        let flashcards = FlashcardsInteractor(expressions: expressions, cards: cards)
        let clock = ContinuousClock()
        var first: StudyStats?, second: StudyStats?
        let cold = try await clock.measure { first = try await flashcards.stats(now: now) }
        let warm = try await clock.measure { second = try await flashcards.stats(now: now) }
        print("deck of 5,000 phrases: stats cold \(cold), warm \(warm)")
        #expect(first == second && first?.inStudy == 5_000)
        #expect(warm < cold)                                    // no second read of the store

        let queue = try await flashcards.queue(now: now)
        let answered = try await flashcards.rate(try #require(queue.first).card, .good, now: now)
        let after = try await flashcards.stats(now: now)
        #expect(after.today.studied == 1)
        #expect(after.distribution.new == 9_999 && after.distribution.learning == 1)
        #expect(try await cards.all().first { $0.id == answered.id } == answered)
    }

    /// Settings: what the deck takes on disk and in memory, with the counts.
    @Test func theDeckFootprintIsReported() async throws {
        let container = try container()
        let expressions = SwiftDataExpressionRepository(modelContainer: container)
        let cards = SwiftDataReviewCardRepository(modelContainer: container)
        let dir = FileManager.default.temporaryDirectory.appending(path: "deckusage-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let reader = StorageUsageReader(modelContainer: container, recordingsDirectory: dir,
                                        phrases: expressions, cards: cards)
        let empty = await reader.usage()
        #expect(empty.deckBytes == 0 && empty.deckMemoryBytes == 0 && empty.phraseCount == 0 && empty.cardCount == 0)

        let p = phrase("to hit the roof", 0)
        try await expressions.add(p)
        try await cards.addMissing(CardDirection.allCases.map { card(p.id, $0) })
        try await cards.appendLog(ReviewLog(cardID: UUID(), rating: .good, state: .new, reviewedAt: now))

        let usage = await reader.usage()
        #expect(usage.phraseCount == 1 && usage.cardCount == 2)
        let texts: [String] = [p.en, p.ru, p.example, p.context] + p.synonyms
        let textBytes: Int = texts.map(\.utf8.count).reduce(0, +)
        let expectedDeck: Int = textBytes + 25 + 2 * 130 + 60
        #expect(usage.deckBytes == expectedDeck)
        #expect(usage.deckMemoryBytes > usage.deckBytes / 2)    // an estimate, of the same order
        #expect(usage.totalBytes == usage.deckBytes)            // nothing else is stored here

        try await expressions.delete(id: p.id)
        try await cards.delete(expressionID: p.id)
        let after = await reader.usage()
        #expect(after.phraseCount == 0 && after.cardCount == 0 && after.deckBytes == 60)   // the log stays
    }

    /// The store answers for a PERIOD: its start included, its end not, nothing later.
    @Test func logsAreReadForAPeriod() async throws {
        let cards = SwiftDataReviewCardRepository(modelContainer: try container())
        let offsets: [TimeInterval] = [-1, 0, 100, 86_399, 86_400, 7 * 86_400]
        for offset in offsets {
            try await cards.appendLog(ReviewLog(cardID: UUID(), rating: .good, state: .new,
                                                reviewedAt: now.addingTimeInterval(offset)))
        }
        let read = try await cards.logs(in: now..<now.addingTimeInterval(86_400))
        #expect(read.map { $0.reviewedAt.timeIntervalSince(now) }.sorted() == [0, 100, 86_399])
    }
}
