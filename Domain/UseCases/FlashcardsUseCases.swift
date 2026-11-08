//
//  FlashcardsUseCases.swift
//  EnglishHelper — Domain (use cases)
//
//  Flashcard practice over the saved expressions: moving an expression into flashcards, today's
//  queue, answering a card (FSRS scheduling), and the Study dashboard's numbers.
//
//  Saving from Say it / Get it / See it puts an expression on the "saved for later" list. The user
//  moves the ones worth learning into flashcards (`enroll`), which creates its two cards — recognition
//  and recall — as `.new`. Saved-for-later = expressions without cards; deleting an expression deletes
//  its cards (StudyListInteractor).
//
//  Today's queue, in order:
//  1. learning / relearning cards due within the learn-ahead window (they're mid-step);
//  2. review cards due before the end of today, oldest due first;
//  3. new cards in the order they were moved in, up to `newCardsPerDay` (cards first answered today
//     count). A recall card is introduced only after its recognition card was first answered on an
//     earlier day — you learn to understand a phrase before you're asked to produce it.
//

import Foundation

/// A card together with the expression it asks about.
public struct Flashcard: Sendable, Equatable, Identifiable {
    public let card: ReviewCard
    public let expression: Expression
    public var id: UUID { card.id }

    public init(card: ReviewCard, expression: Expression) {
        self.card = card
        self.expression = expression
    }
}

/// What today's practice holds.
public struct FlashcardsSummary: Sendable, Equatable {
    /// Learning and review cards due today.
    public let due: Int
    /// New cards available today (after the daily limit).
    public let new: Int
    public var total: Int { due + new }

    public init(due: Int, new: Int) {
        self.due = due
        self.new = new
    }
}

/// Cards by how well they're known — the dashboard's distribution bar.
public struct CardDistribution: Sendable, Equatable {
    /// Never answered.
    public let new: Int
    /// In (re)learning steps.
    public let learning: Int
    /// In review with an interval under `matureInterval` days.
    public let young: Int
    /// In review with an interval of `matureInterval` days or more (Anki's "mature").
    public let mature: Int
    public var total: Int { new + learning + young + mature }

    public static let matureInterval = 21

    public init(new: Int, learning: Int, young: Int, mature: Int) {
        self.new = new
        self.learning = learning
        self.young = young
        self.mature = mature
    }
}

/// Answers given on one calendar day.
public struct DailyReviews: Sendable, Equatable {
    /// Start of the day.
    public let day: Date
    public let count: Int

    public init(day: Date, count: Int) {
        self.day = day
        self.count = count
    }
}

/// Everything the Study dashboard shows.
public struct StudyStats: Sendable, Equatable {
    public let today: FlashcardsSummary
    /// Expressions in flashcards.
    public let inStudy: Int
    /// Expressions saved for later (not in flashcards).
    public let saved: Int
    public let distribution: CardDistribution
    /// The last `StudyStats.days` days, oldest first; the last entry is today.
    public let reviewsByDay: [DailyReviews]
    public var reviewsToday: Int { reviewsByDay.last?.count ?? 0 }

    public static let days = 7

    public init(today: FlashcardsSummary, inStudy: Int, saved: Int, distribution: CardDistribution,
                reviewsByDay: [DailyReviews]) {
        self.today = today
        self.inStudy = inStudy
        self.saved = saved
        self.distribution = distribution
        self.reviewsByDay = reviewsByDay
    }
}

public protocol FlashcardsUseCase: Sendable {
    func stats(now: Date) async throws -> StudyStats
    func queue(now: Date) async throws -> [Flashcard]
    /// Move a saved expression into flashcards (both directions). No-op if it's already there.
    func enroll(_ expressionID: UUID, now: Date) async throws
    /// Expressions that are in flashcards — everything else is saved for later.
    func enrolledExpressionIDs() async throws -> Set<UUID>
    /// Answer a card: reschedules it, stores it, logs the answer and returns the card's new state.
    func rate(_ card: ReviewCard, _ rating: ReviewRating, now: Date) async throws -> ReviewCard
    /// How long until the card returns for each possible answer.
    func previews(for card: ReviewCard, now: Date) -> [ReviewRating: TimeInterval]
    /// Learning cards due within this window are shown in the current session rather than later.
    var learnAhead: TimeInterval { get }
}

public struct FlashcardsInteractor: FlashcardsUseCase {
    public static let defaultNewCardsPerDay = 20

    private let expressions: ExpressionRepository
    private let cards: ReviewCardRepository
    private let scheduler: FSRS
    private let newCardsPerDay: Int
    private let calendar: Calendar
    private let analytics: (any AnalyticsTracking)?
    public let learnAhead: TimeInterval = 20 * 60   // Anki's default

    public init(expressions: ExpressionRepository, cards: ReviewCardRepository, scheduler: FSRS = FSRS(),
                newCardsPerDay: Int = FlashcardsInteractor.defaultNewCardsPerDay,
                calendar: Calendar = .current, analytics: (any AnalyticsTracking)? = nil) {
        self.expressions = expressions
        self.cards = cards
        self.scheduler = scheduler
        self.newCardsPerDay = newCardsPerDay
        self.calendar = calendar
        self.analytics = analytics
    }

    public func stats(now: Date) async throws -> StudyStats {
        let deck = try await loadDeck()
        let parts = buildQueue(deck, now: now)

        var new = 0, learning = 0, young = 0, mature = 0
        for card in deck.cards {
            switch card.state {
            case .new: new += 1
            case .learning, .relearning: learning += 1
            case .review:
                let interval = card.lastReview.map { card.due.timeIntervalSince($0) / 86_400 } ?? 0
                if interval >= Double(CardDistribution.matureInterval) { mature += 1 } else { young += 1 }
            }
        }

        let startOfToday = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -(StudyStats.days - 1), to: startOfToday) ?? startOfToday
        let logs = try await cards.logs(since: firstDay)
        var perDay: [Date: Int] = [:]
        for log in logs { perDay[calendar.startOfDay(for: log.reviewedAt), default: 0] += 1 }
        let reviewsByDay = (0..<StudyStats.days).compactMap { offset -> DailyReviews? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DailyReviews(day: day, count: perDay[day] ?? 0)
        }

        return StudyStats(
            today: FlashcardsSummary(due: parts.learning.count + parts.reviews.count, new: parts.new.count),
            inStudy: deck.enrolled.count,
            saved: deck.expressions.count - deck.enrolled.count,
            distribution: CardDistribution(new: new, learning: learning, young: young, mature: mature),
            reviewsByDay: reviewsByDay
        )
    }

    public func queue(now: Date) async throws -> [Flashcard] {
        let parts = buildQueue(try await loadDeck(), now: now)
        return parts.learning + parts.reviews + parts.new
    }

    public func enroll(_ expressionID: UUID, now: Date) async throws {
        let existing = Set(try await cards.all().filter { $0.expressionID == expressionID }.map(\.direction))
        for direction in CardDirection.allCases where !existing.contains(direction) {
            try await cards.save(ReviewCard(expressionID: expressionID, direction: direction, due: now))
        }
    }

    public func enrolledExpressionIDs() async throws -> Set<UUID> {
        Set(try await cards.all().map(\.expressionID))
    }

    public func rate(_ card: ReviewCard, _ rating: ReviewRating, now: Date) async throws -> ReviewCard {
        let next = scheduler.review(card, rating: rating, at: now)
        try await cards.save(next)
        // The answer is stored; the log only feeds the counts, so it mustn't fail the answer.
        try? await cards.appendLog(ReviewLog(cardID: card.id, rating: rating, state: card.state, reviewedAt: now))
        analytics?.track(.flashcardReviewed)
        return next
    }

    public func previews(for card: ReviewCard, now: Date) -> [ReviewRating: TimeInterval] {
        scheduler.preview(card, at: now).mapValues { $0.timeIntervalSince(now) }
    }

    // MARK: Queue

    /// The saved expressions and the cards of those still on the list (orphans are ignored).
    private struct Deck {
        let expressions: [Expression]
        let cards: [ReviewCard]
        let enrolled: [Expression]
        let byExpression: [UUID: [CardDirection: ReviewCard]]
    }

    private func loadDeck() async throws -> Deck {
        let expressions = try await self.expressions.all()
        let ids = Set(expressions.map(\.id))
        let cards = try await self.cards.all().filter { ids.contains($0.expressionID) }
        var byExpression: [UUID: [CardDirection: ReviewCard]] = [:]
        for card in cards { byExpression[card.expressionID, default: [:]][card.direction] = card }
        let enrolled = expressions.filter { byExpression[$0.id] != nil }
        return Deck(expressions: expressions, cards: cards, enrolled: enrolled, byExpression: byExpression)
    }

    private func buildQueue(_ deck: Deck, now: Date)
        -> (learning: [Flashcard], reviews: [Flashcard], new: [Flashcard]) {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let learnAheadLimit = now.addingTimeInterval(learnAhead)
        let introducedToday = deck.cards.filter { ($0.firstReview ?? .distantPast) >= startOfToday }.count

        var learning: [Flashcard] = [], reviews: [Flashcard] = [], candidates: [Flashcard] = []
        for expression in deck.enrolled {
            let cards = deck.byExpression[expression.id] ?? [:]
            for card in cards.values {
                switch card.state {
                case .new:
                    if card.direction == .recall {
                        guard let first = cards[.recognition]?.firstReview, first < startOfToday else { continue }
                    }
                    candidates.append(Flashcard(card: card, expression: expression))
                case .learning, .relearning:
                    if card.due <= learnAheadLimit { learning.append(Flashcard(card: card, expression: expression)) }
                case .review:
                    if card.due < endOfToday { reviews.append(Flashcard(card: card, expression: expression)) }
                }
            }
        }
        learning.sort { $0.card.due < $1.card.due }
        reviews.sort { $0.card.due < $1.card.due }
        // New cards in the order they were moved in (their `due` is the moment of moving).
        candidates.sort { ($0.card.due, $0.card.direction == .recognition ? 0 : 1)
                        < ($1.card.due, $1.card.direction == .recognition ? 0 : 1) }
        let new = Array(candidates.prefix(max(0, newCardsPerDay - introducedToday)))
        return (learning, reviews, new)
    }
}
