//
//  Expression.swift
//  EnglishHelper — Domain
//

import Foundation

/// A curated study-list item.
///
/// Practised in-app as two flashcards (`ReviewCard` — their spaced-repetition state lives there, not
/// here) and exportable to an external SRS app (AlgoApp / Anki) via `DeckExporting`.
public struct Expression: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    /// The English expression.
    public var en: String
    /// Russian translation.
    public var ru: String
    /// One natural English example sentence using the expression.
    public var example: String
    /// 2–3 English near-equivalents.
    public var synonyms: [String]
    /// Free-form usage context.
    public var context: String
    /// User-marked "learned": the expression is retired from flashcard practice (and can be cleaned up).
    public var learned: Bool
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        en: String,
        ru: String,
        example: String = "",
        synonyms: [String] = [],
        context: String = "",
        learned: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.en = en
        self.ru = ru
        self.example = example
        self.synonyms = synonyms
        self.context = context
        self.learned = learned
        self.createdAt = createdAt
    }
}
