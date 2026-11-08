//
//  FlashcardsInteractorTests.swift
//  EnglishHelperTests
//
//  Moving saved expressions into flashcards, today's queue (which cards, in what order, the new-card
//  limit, recognition before recall), answering a card, the dashboard numbers, and cards leaving
//  with their expression.
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

    private func expression(_ en: String, ageDays: Double = 1) -> Domain.Expression {
        Domain.Expression(en: en, ru: "ru " + en, createdAt: now.addingTimeInterval(-ageDays * day))
    }

    /// The two never-answered cards an expression gets when moved in at `movedAt`.
    private func newCards(_ e: Domain.Expression, movedAt: Date) -> [ReviewCard] {
        CardDirection.allCases.map { ReviewCard(expressionID: e.id, direction: $0, due: movedAt) }
    }

    private func make(_ expressions: [Domain.Expression], cards: [ReviewCard] = [], logs: [ReviewLog] = [],
                      newPerDay: Int = 20) -> (FlashcardsInteractor, MockReviewCardRepository) {
        let repo = MockReviewCardRepository(seed: cards, logs: logs)
        let interactor = FlashcardsInteractor(expressions: MockExpressionRepository(seed: expressions), cards: repo,
                                              newCardsPerDay: newPerDay, calendar: calendar)
        return (interactor, repo)
    }

    @Test func savedForLaterIsNotPractised() async throws {
        let (sut, _) = make([expression("a"), expression("b")])
        #expect(try await sut.queue(now: now).isEmpty)
        #expect(try await sut.enrolledExpressionIDs().isEmpty)
    }

    /// Moving in creates both cards (once); the first day asks recognition only.
    @Test func movingInCreatesBothCardsAndStartsWithRecognition() async throws {
        let e = expression("break the ice")
        let (sut, repo) = make([e])
        try await sut.enroll(e.id, now: now)
        try await sut.enroll(e.id, now: now)                       // idempotent
        let cards = try await repo.all()
        #expect(cards.count == 2)
        #expect(Set(cards.map(\.direction)) == [.recognition, .recall])
        #expect(cards.allSatisfy { $0.state == .new })
        #expect(try await sut.enrolledExpressionIDs() == [e.id])

        let queue = try await sut.queue(now: now)
        #expect(queue.map(\.card.direction) == [.recognition])
        #expect(queue.first?.expression.id == e.id)
    }

    /// Recall comes once recognition was first answered on an EARLIER day — not the same day.
    @Test func recallFollowsRecognitionFromAnEarlierDay() async throws {
        let e = expression("a", ageDays: 3)
        let recognition = ReviewCard(expressionID: e.id, direction: .recognition, state: .review,
                                     due: now.addingTimeInterval(2 * day), stability: 3, difficulty: 5,
                                     reps: 2, lastReview: now.addingTimeInterval(-day),
                                     firstReview: now.addingTimeInterval(-day))
        let recall = ReviewCard(expressionID: e.id, direction: .recall, due: now.addingTimeInterval(-2 * day))
        let (sut, _) = make([e], cards: [recognition, recall])
        #expect(try await sut.queue(now: now).map(\.card.direction) == [.recall])

        var introducedToday = recognition
        introducedToday.firstReview = now.addingTimeInterval(-60)
        let (sameDay, _) = make([e], cards: [introducedToday, recall])
        #expect(try await sameDay.queue(now: now).isEmpty)
    }

    /// The daily new-card limit, in the order expressions were moved in; cards first answered today
    /// count against it.
    @Test func newCardsAreCappedPerDayInTheOrderMovedIn() async throws {
        let first = expression("first", ageDays: 1), second = expression("second", ageDays: 5)
        let third = expression("third", ageDays: 3)
        let cards = newCards(first, movedAt: now.addingTimeInterval(-300))
            + newCards(second, movedAt: now.addingTimeInterval(-200))
            + newCards(third, movedAt: now.addingTimeInterval(-100))
        let (sut, _) = make([first, second, third], cards: cards, newPerDay: 2)
        #expect(try await sut.queue(now: now).map(\.expression.en) == ["first", "second"])

        var answeredToday = cards[0]
        answeredToday.state = .learning
        answeredToday.due = now.addingTimeInterval(3_600)
        answeredToday.firstReview = now.addingTimeInterval(-60)
        let (limited, _) = make([first, second, third], cards: [answeredToday] + Array(cards.dropFirst()), newPerDay: 2)
        #expect(try await limited.queue(now: now).map(\.expression.en) == ["second"])
    }

    /// Learning cards due soon first, then reviews due today, then new; later reviews wait.
    @Test func queueOrder() async throws {
        let learning = expression("learning", ageDays: 4), review = expression("review", ageDays: 5)
        let later = expression("later", ageDays: 6), fresh = expression("fresh", ageDays: 1)
        let cards = [
            ReviewCard(expressionID: learning.id, direction: .recognition, state: .learning,
                       due: now.addingTimeInterval(300), stability: 3, difficulty: 5, step: 1, reps: 1,
                       lastReview: now.addingTimeInterval(-300), firstReview: now.addingTimeInterval(-300)),
            ReviewCard(expressionID: review.id, direction: .recognition, state: .review,
                       due: now.addingTimeInterval(-day), stability: 5, difficulty: 5, reps: 3,
                       lastReview: now.addingTimeInterval(-6 * day), firstReview: now.addingTimeInterval(-6 * day)),
            ReviewCard(expressionID: later.id, direction: .recognition, state: .review,
                       due: now.addingTimeInterval(3 * day), stability: 5, difficulty: 5, reps: 3,
                       lastReview: now.addingTimeInterval(-2 * day), firstReview: now.addingTimeInterval(-10 * day)),
        ] + newCards(fresh, movedAt: now.addingTimeInterval(-60))
        let (sut, _) = make([learning, review, later, fresh], cards: cards)
        let queue = try await sut.queue(now: now)
        #expect(queue.map { "\($0.expression.en).\($0.card.direction)" } == [
            "learning.recognition", "review.recognition", "fresh.recognition",
        ])
    }

    @Test func answeringStoresTheCardAndLogsIt() async throws {
        let e = expression("a")
        let (sut, repo) = make([e])
        try await sut.enroll(e.id, now: now)
        let card = try #require(try await sut.queue(now: now).first).card
        let answered = try await sut.rate(card, .good, now: now)
        #expect(answered.state == .learning)
        #expect(try await repo.all().first { $0.id == card.id } == answered)
        let logs = try await repo.logs(since: now.addingTimeInterval(-60))
        #expect(logs.map(\.rating) == [.good])
        #expect(logs.first?.state == .new)
        // Still in today's queue — the 10-minute step is inside the learn-ahead window.
        #expect(try await sut.queue(now: now.addingTimeInterval(60)).map(\.card.id) == [card.id])
        #expect(sut.previews(for: answered, now: now)[.again] == 60)
    }

    /// The dashboard: today's counts, phrases in study vs caught, cards by stage (young vs
    /// mature at 21 days), answers per day for the last week.
    @Test func statsForTheDashboard() async throws {
        let studied = expression("studied", ageDays: 40), saved = expression("saved")
        let cards = [
            ReviewCard(expressionID: studied.id, direction: .recognition, state: .review,
                       due: now.addingTimeInterval(30 * day), stability: 30, difficulty: 5, reps: 5,
                       lastReview: now.addingTimeInterval(-day), firstReview: now.addingTimeInterval(-30 * day)),
            ReviewCard(expressionID: studied.id, direction: .recall, state: .review,
                       due: now.addingTimeInterval(-60), stability: 4, difficulty: 5, reps: 3,
                       lastReview: now.addingTimeInterval(-4 * day), firstReview: now.addingTimeInterval(-20 * day)),
        ]
        let logs = [
            ReviewLog(cardID: cards[0].id, rating: .good, state: .review, reviewedAt: now.addingTimeInterval(-60)),
            ReviewLog(cardID: cards[1].id, rating: .again, state: .review, reviewedAt: now.addingTimeInterval(-120)),
            ReviewLog(cardID: cards[1].id, rating: .good, state: .review, reviewedAt: now.addingTimeInterval(-2 * day)),
            ReviewLog(cardID: cards[1].id, rating: .good, state: .review, reviewedAt: now.addingTimeInterval(-30 * day)),
        ]
        let (sut, _) = make([studied, saved], cards: cards, logs: logs)
        let stats = try await sut.stats(now: now)
        #expect(stats.today == FlashcardsSummary(due: 1, new: 0))
        #expect(stats.inStudy == 1)
        #expect(stats.caught == 1)
        #expect(stats.distribution == CardDistribution(new: 0, learning: 0, young: 1, mature: 1))
        #expect(stats.reviewsByDay.count == 7)
        #expect(stats.reviewsToday == 2)
        #expect(stats.reviewsByDay.map(\.count) == [0, 0, 0, 0, 1, 0, 2])   // the 30-day-old answer is out
        #expect(stats.reviewsByDay.last?.day == calendar.startOfDay(for: now))
    }

    @Test func deletingAnExpressionDeletesItsCards() async throws {
        let e = expression("a")
        let expressions = MockExpressionRepository(seed: [e])
        let cards = MockReviewCardRepository(seed: newCards(e, movedAt: now)
            + [ReviewCard(expressionID: UUID(), direction: .recognition, due: now)])
        try await StudyListInteractor(repository: expressions, cards: cards).delete(id: e.id)
        #expect(try await cards.all().count == 1)
    }
}
