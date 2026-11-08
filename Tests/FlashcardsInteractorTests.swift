//
//  FlashcardsInteractorTests.swift
//  EnglishHelperTests
//
//  Today's flashcard queue (which cards, in what order, the new-card limit, recognition before
//  recall), answering a card, and cards leaving with their expression.
//

import Testing
import Foundation
import Domain
import Adapters

@Suite struct FlashcardsInteractorTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 86_400
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func expression(_ en: String, ageDays: Double = 1, learned: Bool = false) -> Domain.Expression {
        Domain.Expression(en: en, ru: "ru " + en, learned: learned, createdAt: now.addingTimeInterval(-ageDays * day))
    }

    private func make(_ expressions: [Domain.Expression], cards: [ReviewCard] = [], newPerDay: Int = 20)
        -> (FlashcardsInteractor, MockReviewCardRepository) {
        let repo = MockReviewCardRepository(seed: cards)
        let interactor = FlashcardsInteractor(expressions: MockExpressionRepository(seed: expressions), cards: repo,
                                              newCardsPerDay: newPerDay, calendar: calendar)
        return (interactor, repo)
    }

    @Test func newExpressionStartsWithRecognitionOnly() async throws {
        let e = expression("break the ice")
        let (sut, _) = make([e])
        let queue = try await sut.queue(now: now)
        #expect(queue.count == 1)
        #expect(queue.first?.card.direction == .recognition)
        #expect(queue.first?.card.state == .new)
        #expect(queue.first?.expression.id == e.id)
    }

    @Test func learnedExpressionsAreLeftOut() async throws {
        let (sut, _) = make([expression("a"), expression("b", learned: true)])
        let queue = try await sut.queue(now: now)
        #expect(queue.map(\.expression.en) == ["a"])
    }

    /// Recall comes once recognition was first answered on an EARLIER day — not the same day.
    @Test func recallFollowsRecognitionFromAnEarlierDay() async throws {
        let e = expression("a", ageDays: 3)
        let introducedYesterday = ReviewCard(expressionID: e.id, direction: .recognition, state: .review,
                                             due: now.addingTimeInterval(2 * day), stability: 3, difficulty: 5,
                                             reps: 2, lastReview: now.addingTimeInterval(-day),
                                             firstReview: now.addingTimeInterval(-day))
        let (sut, _) = make([e], cards: [introducedYesterday])
        let queue = try await sut.queue(now: now)
        #expect(queue.map(\.card.direction) == [.recall])

        var introducedToday = introducedYesterday
        introducedToday.firstReview = now.addingTimeInterval(-60)
        let (sameDay, _) = make([e], cards: [introducedToday])
        #expect(try await sameDay.queue(now: now).isEmpty)
    }

    /// The daily new-card limit, with cards already introduced today counting against it; oldest
    /// expressions first.
    @Test func newCardsAreCappedPerDay() async throws {
        let old = expression("old", ageDays: 5), mid = expression("mid", ageDays: 3), young = expression("young", ageDays: 1)
        let (sut, _) = make([young, old, mid], newPerDay: 2)
        #expect(try await sut.queue(now: now).map(\.expression.en) == ["old", "mid"])

        let introduced = ReviewCard(expressionID: UUID(), direction: .recognition, state: .learning,
                                    due: now.addingTimeInterval(3_600), stability: 3, difficulty: 5, reps: 1,
                                    lastReview: now.addingTimeInterval(-60), firstReview: now.addingTimeInterval(-60))
        let (limited, _) = make([young, old, mid], cards: [introduced], newPerDay: 2)
        #expect(try await limited.queue(now: now).map(\.expression.en) == ["old"])
    }

    /// Learning cards due soon first, then reviews due today, then new (oldest expression first —
    /// including recall cards whose recognition was introduced on an earlier day); later reviews wait.
    @Test func queueOrder() async throws {
        let learning = expression("learning", ageDays: 4), review = expression("review", ageDays: 5)
        let later = expression("later", ageDays: 6), fresh = expression("fresh", ageDays: 1)
        let cards = [
            // Introduced today, mid-step → shown; its recall waits for another day.
            ReviewCard(expressionID: learning.id, direction: .recognition, state: .learning,
                       due: now.addingTimeInterval(300), stability: 3, difficulty: 5, step: 1, reps: 1,
                       lastReview: now.addingTimeInterval(-300), firstReview: now.addingTimeInterval(-300)),
            // Overdue review → shown; recall is new and eligible.
            ReviewCard(expressionID: review.id, direction: .recognition, state: .review,
                       due: now.addingTimeInterval(-day), stability: 5, difficulty: 5, reps: 3,
                       lastReview: now.addingTimeInterval(-6 * day), firstReview: now.addingTimeInterval(-6 * day)),
            // Due in 3 days → not today; recall is new and eligible.
            ReviewCard(expressionID: later.id, direction: .recognition, state: .review,
                       due: now.addingTimeInterval(3 * day), stability: 5, difficulty: 5, reps: 3,
                       lastReview: now.addingTimeInterval(-2 * day), firstReview: now.addingTimeInterval(-10 * day)),
        ]
        let (sut, _) = make([learning, review, later, fresh], cards: cards)
        let queue = try await sut.queue(now: now)
        #expect(queue.map { "\($0.expression.en).\($0.card.direction)" } == [
            "learning.recognition", "review.recognition",
            "later.recall", "review.recall", "fresh.recognition",
        ])
        #expect(try await sut.summary(now: now) == FlashcardsSummary(due: 2, new: 3))
    }

    @Test func answeringStoresTheCard() async throws {
        let e = expression("a")
        let (sut, repo) = make([e])
        let card = try #require(try await sut.queue(now: now).first).card
        let answered = try await sut.rate(card, .good, now: now)
        #expect(answered.state == .learning)
        #expect(try await repo.all() == [answered])
        // Still in today's queue — the 10-minute step is inside the learn-ahead window.
        let again = try await sut.queue(now: now.addingTimeInterval(60))
        #expect(again.map(\.card.id) == [card.id])
        #expect(sut.previews(for: answered, now: now)[.again] == 60)
    }

    @Test func deletingAnExpressionDeletesItsCards() async throws {
        let e = expression("a")
        let expressions = MockExpressionRepository(seed: [e])
        let cards = MockReviewCardRepository(seed: [
            ReviewCard(expressionID: e.id, direction: .recognition, due: now),
            ReviewCard(expressionID: e.id, direction: .recall, due: now),
            ReviewCard(expressionID: UUID(), direction: .recognition, due: now),
        ])
        try await StudyListInteractor(repository: expressions, cards: cards).delete(id: e.id)
        #expect(try await cards.all().count == 1)
    }
}
