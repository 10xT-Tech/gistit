//
//  ReviewCard.swift
//  EnglishHelper — Domain
//
//  One flashcard: a saved expression asked in ONE direction, plus its spaced-repetition memory state
//  (FSRS — see `FSRS`). An expression the user moved to flashcards has two, scheduled independently:
//  recognition (studied language → meaning) and recall (meaning → studied language). Expressions
//  without cards are the "saved for later" list.
//

import Foundation

public enum CardDirection: String, Codable, Sendable, CaseIterable {
    /// Shows the studied-language expression; the user recalls what it means.
    case recognition
    /// Shows the meaning in the native language; the user recalls the studied-language expression.
    case recall
}

/// Where a card is in the FSRS life cycle.
public enum ReviewState: String, Codable, Sendable {
    /// Never answered.
    case new
    /// Being introduced: short same-day steps (minutes) before its first interval in days.
    case learning
    /// Graduated: next shown after an interval in days.
    case review
    /// Forgotten (answered "Again" in review): short steps again before returning to review.
    case relearning
}

/// The four answer buttons. Raw value = the FSRS grade.
public enum ReviewRating: Int, Codable, Sendable, CaseIterable, Comparable {
    case again = 1, hard, good, easy

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ReviewCard: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let expressionID: UUID
    public let direction: CardDirection
    public var state: ReviewState
    /// When the card is next shown.
    public var due: Date
    /// FSRS memory stability in days — the interval at which recall probability falls to 90%.
    /// 0 until the first answer.
    public var stability: Double
    /// FSRS difficulty, 1…10. 0 until the first answer.
    public var difficulty: Double
    /// Index into the (re)learning steps while `state` is `.learning` / `.relearning`.
    public var step: Int
    /// Answers given, and how many of them were a lapse (review → "Again").
    public var reps: Int
    public var lapses: Int
    public var lastReview: Date?
    /// When the card was first answered — counts it against the day's new-card limit.
    public var firstReview: Date?

    public init(
        id: UUID = UUID(),
        expressionID: UUID,
        direction: CardDirection,
        state: ReviewState = .new,
        due: Date,
        stability: Double = 0,
        difficulty: Double = 0,
        step: Int = 0,
        reps: Int = 0,
        lapses: Int = 0,
        lastReview: Date? = nil,
        firstReview: Date? = nil
    ) {
        self.id = id
        self.expressionID = expressionID
        self.direction = direction
        self.state = state
        self.due = due
        self.stability = stability
        self.difficulty = difficulty
        self.step = step
        self.reps = reps
        self.lapses = lapses
        self.lastReview = lastReview
        self.firstReview = firstReview
    }
}

/// One answer, kept for the daily review counts (and, later, for fitting FSRS to the user).
public struct ReviewLog: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let cardID: UUID
    public let rating: ReviewRating
    /// The card's state when it was answered.
    public let state: ReviewState
    public let reviewedAt: Date

    public init(id: UUID = UUID(), cardID: UUID, rating: ReviewRating, state: ReviewState, reviewedAt: Date) {
        self.id = id
        self.cardID = cardID
        self.rating = rating
        self.state = state
        self.reviewedAt = reviewedAt
    }
}
