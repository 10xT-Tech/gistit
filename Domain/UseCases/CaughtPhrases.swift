//
//  CaughtPhrases.swift
//  EnglishHelper — Domain (use cases)
//
//  What a phrase about to be saved into Caught is compared with. The user's rule: a phrase is NOT added
//  only when Caught already holds the very same phrase in the studied language (letter case and spaces at
//  the ends aside — `Expression.matchKey`). A phrase that is already in FLASHCARDS is added
//  all the same: the Caught list marks it ("Already in flashcards"), and moving it offers the merge.
//

import Foundation

public struct CaughtPhrases: Sendable {
    private let expressions: ExpressionRepository
    /// Nil: nothing is in flashcards (tests, the boots without flashcards) — every phrase is in Caught.
    private let cards: (any ReviewCardRepository)?

    public init(expressions: ExpressionRepository, cards: (any ReviewCardRepository)?) {
        self.expressions = expressions
        self.cards = cards
    }

    /// The phrase in Caught with this studied-language text, oldest first — nil if there's none (one in
    /// flashcards doesn't count).
    public func inCaught(_ en: String) async throws -> Expression? {
        let same = try await matching(en)
        guard !same.isEmpty else { return nil }
        let enrolled = try await enrolledIDs()
        return same.first { !enrolled.contains($0.id) }
    }

    /// Whether a phrase in flashcards has this studied-language text.
    public func inFlashcards(_ en: String) async throws -> Bool {
        let same = try await matching(en)
        guard !same.isEmpty else { return false }
        let enrolled = try await enrolledIDs()
        return same.contains { enrolled.contains($0.id) }
    }

    private func matching(_ en: String) async throws -> [Expression] {
        let key = Expression.matchKey(en)
        return try await expressions.all()
            .filter { Expression.matchKey($0.en) == key }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func enrolledIDs() async throws -> Set<UUID> {
        guard let cards else { return [] }
        return Set(try await cards.all().map(\.expressionID))
    }
}

public extension Expression {
    /// Two studied-language texts are the same phrase when these are equal: letter case and spaces at
    /// the ends aside, nothing else ("Hit the roof" = "hit the roof ", but not "hit the roof!").
    static func matchKey(_ en: String) -> String {
        en.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
