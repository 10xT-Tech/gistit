//
//  PersistenceModels.swift
//  EnglishHelper — Data (SwiftData)
//
//  SwiftData @Model classes + mapping to/from the Domain entities. Persistence types never leave
//  the Data layer; repositories hand back pure Domain values.
//

import Foundation
import SwiftData
import Domain

@Model
public final class ExpressionModel {
    @Attribute(.unique) public var id: UUID
    public var en: String
    public var ru: String
    public var example: String
    public var synonyms: [String]
    public var context: String
    public var learned: Bool
    public var createdAt: Date

    public init(_ e: Domain.Expression) {
        self.id = e.id
        self.en = e.en
        self.ru = e.ru
        self.example = e.example
        self.synonyms = e.synonyms
        self.context = e.context
        self.learned = e.learned
        self.createdAt = e.createdAt
    }

    public func apply(_ e: Domain.Expression) {
        en = e.en; ru = e.ru; example = e.example
        synonyms = e.synonyms; context = e.context; learned = e.learned
    }

    public func toDomain() -> Domain.Expression {
        Domain.Expression(id: id, en: en, ru: ru, example: example,
                          synonyms: synonyms, context: context, learned: learned, createdAt: createdAt)
    }
}

/// A flashcard's spaced-repetition state (`Domain.ReviewCard`). Linked to its expression by id, not a
/// relationship — so adding it left `ExpressionModel` untouched (a purely additive migration).
@Model
public final class ReviewCardModel {
    @Attribute(.unique) public var id: UUID
    public var expressionID: UUID
    public var directionRaw: String
    public var stateRaw: String
    public var due: Date
    public var stability: Double
    public var difficulty: Double
    public var step: Int
    public var reps: Int
    public var lapses: Int
    public var lastReview: Date?
    public var firstReview: Date?

    public init(_ c: ReviewCard) {
        self.id = c.id
        self.expressionID = c.expressionID
        self.directionRaw = c.direction.rawValue
        self.stateRaw = c.state.rawValue
        self.due = c.due
        self.stability = c.stability
        self.difficulty = c.difficulty
        self.step = c.step
        self.reps = c.reps
        self.lapses = c.lapses
        self.lastReview = c.lastReview
        self.firstReview = c.firstReview
    }

    public func apply(_ c: ReviewCard) {
        stateRaw = c.state.rawValue; due = c.due
        stability = c.stability; difficulty = c.difficulty; step = c.step
        reps = c.reps; lapses = c.lapses; lastReview = c.lastReview; firstReview = c.firstReview
    }

    /// Nil for a row whose direction / state this build doesn't know (written by a newer version).
    public func toDomain() -> ReviewCard? {
        guard let direction = CardDirection(rawValue: directionRaw),
              let state = ReviewState(rawValue: stateRaw) else { return nil }
        return ReviewCard(id: id, expressionID: expressionID, direction: direction, state: state, due: due,
                          stability: stability, difficulty: difficulty, step: step, reps: reps,
                          lapses: lapses, lastReview: lastReview, firstReview: firstReview)
    }
}

/// A cached text-translation request: `key` is `Domain.TranslationCacheKey`, `value` is the JSON of the
/// scenario's typed result. Lets repeat translations of the same input skip the model entirely.
@Model
public final class CachedTranslationModel {
    @Attribute(.unique) public var key: String
    public var value: Data
    public var createdAt: Date

    public init(key: String, value: Data, createdAt: Date = Date()) {
        self.key = key
        self.value = value
        self.createdAt = createdAt
    }
}

@Model
public final class HistoryModel {
    @Attribute(.unique) public var id: UUID
    public var kindRaw: String
    public var inputText: String
    /// `RequestResult` encoded as JSON (it's a typed enum payload).
    public var resultData: Data
    public var createdAt: Date

    public init(_ entry: HistoryEntry) throws {
        self.id = entry.id
        self.kindRaw = entry.kind.rawValue
        self.inputText = entry.inputText
        self.createdAt = entry.createdAt
        do {
            self.resultData = try JSONEncoder().encode(entry.result)
        } catch {
            throw RepositoryError.persistenceFailed("encode history result: \(error)")
        }
    }

    public func toDomain() throws -> HistoryEntry {
        do {
            let result = try JSONDecoder().decode(RequestResult.self, from: resultData)
            return HistoryEntry(id: id, inputText: inputText, result: result, createdAt: createdAt)
        } catch {
            throw RepositoryError.persistenceFailed("decode history result: \(error)")
        }
    }
}
