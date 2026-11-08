//
//  FlashcardsUseCases.swift
//  EnglishHelper — Domain (use cases)
//
//  Flashcard practice over the study list: today's queue and answering a card (FSRS scheduling).
//
//  Every expression that isn't marked learned has two cards, recognition and recall. A card that was
//  never answered isn't stored — the queue makes it up as `.new` and `rate` stores it, so the study
//  list and the cards can't drift apart (deleting an expression deletes its cards; marking it learned
//  just keeps it out of the queue).
//
//  Today's queue, in order:
//  1. learning / relearning cards due within the learn-ahead window (they're mid-step);
//  2. review cards due before the end of today, oldest due first;
//  3. new cards, oldest expression first, up to `newCardsPerDay` (cards first answered today count).
//  An expression's recall card is introduced only after its recognition card was first answered on
//  an earlier day — you learn to understand a phrase before you're asked to produce it.
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

/// Counts for the Study screen's practice card.
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

public protocol FlashcardsUseCase: Sendable {
    func summary(now: Date) async throws -> FlashcardsSummary
    func queue(now: Date) async throws -> [Flashcard]
    /// Answer a card: reschedules it, stores it and returns its new state.
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

    public func summary(now: Date) async throws -> FlashcardsSummary {
        let parts = try await buildQueue(now: now)
        return FlashcardsSummary(due: parts.learning.count + parts.reviews.count, new: parts.new.count)
    }

    public func queue(now: Date) async throws -> [Flashcard] {
        let parts = try await buildQueue(now: now)
        return parts.learning + parts.reviews + parts.new
    }

    public func rate(_ card: ReviewCard, _ rating: ReviewRating, now: Date) async throws -> ReviewCard {
        let next = scheduler.review(card, rating: rating, at: now)
        try await cards.save(next)
        analytics?.track(.flashcardReviewed)
        return next
    }

    public func previews(for card: ReviewCard, now: Date) -> [ReviewRating: TimeInterval] {
        scheduler.preview(card, at: now).mapValues { $0.timeIntervalSince(now) }
    }

    // MARK: Queue

    private func buildQueue(now: Date) async throws
        -> (learning: [Flashcard], reviews: [Flashcard], new: [Flashcard]) {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let learnAheadLimit = now.addingTimeInterval(learnAhead)

        let stored = try await cards.all()
        var byExpression: [UUID: [CardDirection: ReviewCard]] = [:]
        for card in stored { byExpression[card.expressionID, default: [:]][card.direction] = card }
        let introducedToday = stored.filter { ($0.firstReview ?? .distantPast) >= startOfToday }.count
        var newBudget = max(0, newCardsPerDay - introducedToday)

        var learning: [Flashcard] = [], reviews: [Flashcard] = [], new: [Flashcard] = []
        let active = try await expressions.all()
            .filter { !$0.learned }
            .sorted { $0.createdAt < $1.createdAt }
        for expression in active {
            let existing = byExpression[expression.id] ?? [:]
            for direction in CardDirection.allCases {
                guard let card = existing[direction] else {
                    // Never answered: new — recall only once recognition was introduced on an earlier day.
                    if direction == .recall {
                        guard let recognition = existing[.recognition], let first = recognition.firstReview,
                              first < startOfToday else { continue }
                    }
                    guard newBudget > 0 else { continue }
                    newBudget -= 1
                    let card = ReviewCard(expressionID: expression.id, direction: direction, due: now)
                    new.append(Flashcard(card: card, expression: expression))
                    continue
                }
                switch card.state {
                case .learning, .relearning:
                    if card.due <= learnAheadLimit { learning.append(Flashcard(card: card, expression: expression)) }
                case .review:
                    if card.due < endOfToday { reviews.append(Flashcard(card: card, expression: expression)) }
                case .new:
                    break   // stored cards are always answered at least once
                }
            }
        }
        learning.sort { $0.card.due < $1.card.due }
        reviews.sort { $0.card.due < $1.card.due }
        return (learning, reviews, new)
    }
}
