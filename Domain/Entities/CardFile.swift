//
//  CardFile.swift
//  EnglishHelper — Domain
//
//  The app's own card file — JSON, `"format": "gist-it-cards"`, versioned. Export writes the cards in
//  flashcards with their learning progress (FSRS state per direction); import reads the same file —
//  or a hand-made / converted one with only the text fields (an AlgoApp deck converted by
//  tools/algoapp_to_cards.py) — straight into flashcards.
//
//  {
//    "format": "gist-it-cards", "version": 1, "exportedAt": "2026-11-08T16:40:00Z",
//    "cards": [
//      { "expression": "jump the gun", "translation": "поторопиться",
//        "example": "Don't jump the gun.", "synonyms": ["rush", "act too soon"], "context": "…",
//        "review": [ { "direction": "recognition", "state": "review", "due": "…", "stability": 4.5,
//                      "difficulty": 5.2, "step": 0, "reps": 2, "lapses": 0,
//                      "lastReview": "…", "firstReview": "…" } ],
//        "notDuplicateOf": ["jump the gun!"] }
//    ]
//  }
//  Only "expression" and "translation" are required; "review" and "notDuplicateOf" (the expressions of
//  the other cards in the file it was marked "not duplicates" with) are present in exports only.
//

import Foundation

public struct CardFile: Codable, Sendable, Equatable {
    public static let formatName = "gist-it-cards"
    public static let currentVersion = 1

    public struct Card: Codable, Sendable, Equatable {
        public var expression: String
        public var translation: String
        public var example: String?
        public var synonyms: [String]?
        public var context: String?
        /// The learning progress, one entry per direction (exports only).
        public var review: [Review]?
        /// The expressions of the cards in this file it was marked "not duplicates" with (exports only).
        public var notDuplicateOf: [String]?

        public init(expression: String, translation: String, example: String? = nil, synonyms: [String]? = nil,
                    context: String? = nil, review: [Review]? = nil, notDuplicateOf: [String]? = nil) {
            self.expression = expression
            self.translation = translation
            self.example = example
            self.synonyms = synonyms
            self.context = context
            self.review = review
            self.notDuplicateOf = notDuplicateOf
        }
    }

    /// One direction's FSRS state.
    public struct Review: Codable, Sendable, Equatable {
        public var direction: CardDirection
        public var state: ReviewState
        public var due: Date
        public var stability: Double
        public var difficulty: Double
        public var step: Int?
        public var reps: Int
        public var lapses: Int
        public var lastReview: Date?
        public var firstReview: Date?

        public init(_ card: ReviewCard) {
            direction = card.direction
            state = card.state
            due = card.due
            stability = card.stability
            difficulty = card.difficulty
            step = card.step
            reps = card.reps
            lapses = card.lapses
            lastReview = card.lastReview
            firstReview = card.firstReview
        }

        /// The card this entry restores, for `expressionID`.
        public func card(for expressionID: UUID) -> ReviewCard {
            ReviewCard(expressionID: expressionID, direction: direction, state: state, due: due,
                       stability: stability, difficulty: difficulty, step: step ?? 0, reps: reps,
                       lapses: lapses, lastReview: lastReview, firstReview: firstReview)
        }
    }

    public var format: String
    public var version: Int
    public var exportedAt: Date?
    /// Where the cards came from (free text, informational).
    public var source: String?
    public var cards: [Card]

    public init(cards: [Card], exportedAt: Date? = nil, source: String? = nil) {
        self.format = Self.formatName
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.source = source
        self.cards = cards
    }

    /// Reads a card file; throws `CardFileError` for anything that isn't one this app can read.
    public static func decode(_ data: Data) throws -> CardFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = isoWithFraction.date(from: text) ?? iso.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not an ISO 8601 date: \(text)"))
        }
        let file: CardFile
        do {
            file = try decoder.decode(CardFile.self, from: data)
        } catch {
            throw CardFileError.notACardFile
        }
        guard file.format == formatName else { throw CardFileError.notACardFile }
        guard file.version <= currentVersion else { throw CardFileError.newerVersion(file.version) }
        return file
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.isoWithFraction.string(from: date))
        }
        return try encoder.encode(self)
    }

    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

public enum CardFileError: Error, Equatable {
    /// Not JSON, or not a "gist-it-cards" file.
    case notACardFile
    /// Written by a newer version of the app.
    case newerVersion(Int)
}
