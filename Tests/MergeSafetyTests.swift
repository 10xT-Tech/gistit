//
//  MergeSafetyTests.swift
//  EnglishHelperTests
//
//  A merge of duplicates is never left half-done with the learning progress gone: the cards change
//  in one all-or-nothing write (`ReviewCardRepository.replaceCards`), a failure at any step loses no
//  card, a retry completes what a failed step left, and a group with no cards at all isn't merged
//  (it would only delete phrases). The SwiftData store replaces the cards in place.
//

import Testing
import Foundation
import SwiftData
import Domain
import Adapters

@Suite struct MergeSafetyTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let merged = CardText(expression: "to hit the roof", translation: "взбеситься", example: "",
                                  synonyms: ["go mad"], context: "разговорное.")

    private func phrase(_ en: String, _ minute: Double) -> Domain.Expression {
        Domain.Expression(en: en, ru: "взбеситься", createdAt: now.addingTimeInterval(minute * 60))
    }

    private func cards(_ e: Domain.Expression, stability: Double) -> [ReviewCard] {
        CardDirection.allCases.map {
            ReviewCard(expressionID: e.id, direction: $0, state: .review, due: now, stability: stability,
                       difficulty: 5, reps: 3, lastReview: now.addingTimeInterval(-86_400))
        }
    }

    private func merge(_ sut: DuplicatesInteractor, _ group: [Domain.Expression]) async throws {
        try await sut.merge(group, into: merged, as: .duplicate, studiedLanguage: "English", nativeLanguage: "Russian")
    }

    /// The card write fails: every card and every phrase is still there — nothing to recover.
    @Test func aFailedCardWriteLosesNothing() async throws {
        let a = phrase("hit the roof", 0), b = phrase("to hit the roof", 1)
        let all = cards(a, stability: 3) + cards(b, stability: 30)
        let expressions = MockExpressionRepository(seed: [a, b])
        let reviewCards = FlakyCards(seed: all, failures: 1)
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions, cards: reviewCards)

        await #expect(throws: RepositoryError.self) { try await merge(sut, [a, b]) }
        #expect(Set(try await reviewCards.all()) == Set(all))
        #expect(Set(try await expressions.all().map(\.id)) == [a.id, b.id])

        // The next try completes it, with the best-known cards.
        try await merge(sut, [a, b])
        let kept = try await reviewCards.all()
        #expect(kept.count == 2 && kept.allSatisfy { $0.expressionID == a.id && $0.stability == 30 })
        #expect(try await expressions.all().map(\.id) == [a.id])
    }

    /// Deleting the merged-away phrase fails after the cards were merged: the progress is on the kept
    /// phrase, the other one waits (without cards) — and the next try removes it, the cards untouched.
    @Test func aFailedPhraseDeleteIsCompletedByARetry() async throws {
        let a = phrase("hit the roof", 0), b = phrase("to hit the roof", 1)
        let bCards = cards(b, stability: 30)
        let expressions = FlakyExpressions(seed: [a, b], deleteFailures: 1)
        let reviewCards = MockReviewCardRepository(seed: cards(a, stability: 3) + bCards)
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions, cards: reviewCards)

        await #expect(throws: RepositoryError.self) { try await merge(sut, [a, b]) }
        var kept = try await reviewCards.all()
        #expect(Set(kept.map(\.id)) == Set(bCards.map(\.id)) && kept.allSatisfy { $0.expressionID == a.id })
        #expect(try await expressions.all().count == 2)

        try await merge(sut, [a, b])
        kept = try await reviewCards.all()
        #expect(Set(kept.map(\.id)) == Set(bCards.map(\.id)) && kept.allSatisfy { $0.stability == 30 })
        #expect(try await expressions.all().map(\.id) == [a.id])
    }

    /// No card in the group (their cards were lost): merging would only delete phrases — refused.
    @Test func aGroupWithNoCardsIsNotMerged() async throws {
        let a = phrase("hit the roof", 0), b = phrase("to hit the roof", 1)
        let expressions = MockExpressionRepository(seed: [a, b])
        let sut = DuplicatesInteractor(llm: MockLLMClient(), expressions: expressions, cards: MockReviewCardRepository())
        await #expect(throws: RepositoryError.notFound) { try await merge(sut, [a, b]) }
        let left = try await expressions.all()
        #expect(Set(left.map(\.id)) == [a.id, b.id])
        #expect(left.first { $0.id == a.id }?.en == "hit the roof")                // not even the texts
    }

    /// The store: kept cards are updated in place (also onto another phrase), the group's other cards
    /// go, and cards outside the group stay.
    @Test func theStoreReplacesCardsInPlace() async throws {
        let container = try ModelContainer(for: ReviewCardModel.self, ReviewLogModel.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repo = SwiftDataReviewCardRepository(modelContainer: container)
        let a = phrase("hit the roof", 0), b = phrase("to hit the roof", 1), other = phrase("solid", 2)
        let aCards = cards(a, stability: 3), bCards = cards(b, stability: 30), otherCards = cards(other, stability: 7)
        try await repo.saveAll(aCards + bCards + otherCards)

        // Recognition: b's card moves to a; recall: a's own card stays.
        let from = bCards[0]
        let moved = ReviewCard(id: from.id, expressionID: a.id, direction: from.direction, state: from.state,
                               due: from.due, stability: from.stability, difficulty: from.difficulty,
                               reps: from.reps, lastReview: from.lastReview)
        try await repo.replaceCards(of: [a.id, b.id], with: [moved, aCards[1]])

        let stored = try await repo.all()
        #expect(Set(stored.map(\.id)) == Set([bCards[0].id, aCards[1].id] + otherCards.map(\.id)))
        let recognition = try #require(stored.first { $0.id == bCards[0].id })
        #expect(recognition.expressionID == a.id && recognition.stability == 30)
        #expect(Set(stored.filter { $0.expressionID == other.id }) == Set(otherCards))
    }
}

/// Cards whose all-or-nothing replacement fails the first `failures` times — leaving them untouched.
private actor FlakyCards: ReviewCardRepository {
    private let inner: MockReviewCardRepository
    private var failures: Int

    init(seed: [ReviewCard], failures: Int) {
        self.inner = MockReviewCardRepository(seed: seed)
        self.failures = failures
    }

    func all() async throws -> [ReviewCard] { try await inner.all() }
    func save(_ card: ReviewCard) async throws { try await inner.save(card) }
    func delete(expressionID: UUID) async throws { try await inner.delete(expressionID: expressionID) }
    func addMissing(_ cards: [ReviewCard]) async throws { try await inner.addMissing(cards) }
    func replaceCards(of expressionIDs: Set<UUID>, with cards: [ReviewCard]) async throws {
        if failures > 0 {
            failures -= 1
            throw RepositoryError.persistenceFailed("disk full")
        }
        try await inner.replaceCards(of: expressionIDs, with: cards)
    }
    func appendLog(_ log: ReviewLog) async throws { try await inner.appendLog(log) }
    func logs(since date: Date) async throws -> [ReviewLog] { try await inner.logs(since: date) }
}

/// Expressions whose delete fails the first `deleteFailures` times.
private actor FlakyExpressions: ExpressionRepository {
    private let inner: MockExpressionRepository
    private var deleteFailures: Int

    init(seed: [Domain.Expression], deleteFailures: Int) {
        self.inner = MockExpressionRepository(seed: seed)
        self.deleteFailures = deleteFailures
    }

    func all() async throws -> [Domain.Expression] { try await inner.all() }
    func add(_ expression: Domain.Expression) async throws { try await inner.add(expression) }
    func update(_ expression: Domain.Expression) async throws { try await inner.update(expression) }
    func delete(id: Domain.Expression.ID) async throws {
        if deleteFailures > 0 {
            deleteFailures -= 1
            throw RepositoryError.persistenceFailed("disk full")
        }
        try await inner.delete(id: id)
    }
    func setLearned(_ learned: Bool, id: Domain.Expression.ID) async throws { try await inner.setLearned(learned, id: id) }
    func find(en: String) async throws -> Domain.Expression? { try await inner.find(en: en) }
}
