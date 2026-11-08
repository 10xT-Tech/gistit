//
//  CardTransferUseCases.swift
//  EnglishHelper — Domain (use cases)
//
//  Card files (`CardFile`): export the cards in flashcards with their learning progress; import a
//  file straight into flashcards — not via Caught.
//
//  Import, card by card in file order:
//  - a new expression is stored and gets its two cards — restored from the file's "review" entries
//    when present (an export), new otherwise (introduced in file order);
//  - an expression already on the Caught list moves into flashcards the same way;
//  - one already in flashcards is left alone (its progress isn't overwritten);
//  - a repeat of an expression earlier in the file, or one without text, is skipped.
//  Everything is written in two batches, so a large deck (thousands of cards) imports in one go.
//

import Foundation

public struct CardImportReport: Sendable, Equatable {
    /// New expressions, now in flashcards.
    public let added: Int
    /// Expressions that were on the Caught list and moved into flashcards.
    public let movedFromCaught: Int
    /// Expressions already in flashcards — left as they were.
    public let alreadyInFlashcards: Int
    /// Repeats inside the file, and cards without an expression or translation.
    public let skipped: Int

    public var imported: Int { added + movedFromCaught }

    public init(added: Int, movedFromCaught: Int, alreadyInFlashcards: Int, skipped: Int) {
        self.added = added
        self.movedFromCaught = movedFromCaught
        self.alreadyInFlashcards = alreadyInFlashcards
        self.skipped = skipped
    }
}

public protocol CardTransferUseCase: Sendable {
    /// The cards in flashcards, oldest first, with their progress.
    func exportFlashcards(now: Date) async throws -> CardFile
    func importIntoFlashcards(_ file: CardFile, now: Date) async throws -> CardImportReport
}

public struct CardTransferInteractor: CardTransferUseCase {
    private let expressions: ExpressionRepository
    private let cards: ReviewCardRepository

    public init(expressions: ExpressionRepository, cards: ReviewCardRepository) {
        self.expressions = expressions
        self.cards = cards
    }

    public func exportFlashcards(now: Date) async throws -> CardFile {
        let byExpression = Dictionary(grouping: try await cards.all(), by: \.expressionID)
        let enrolled = try await expressions.all()
            .filter { byExpression[$0.id] != nil }
            .sorted { $0.createdAt < $1.createdAt }
        let entries = enrolled.map { expression in
            CardFile.Card(
                expression: expression.en,
                translation: expression.ru,
                example: expression.example.isEmpty ? nil : expression.example,
                synonyms: expression.synonyms.isEmpty ? nil : expression.synonyms,
                context: expression.context.isEmpty ? nil : expression.context,
                review: (byExpression[expression.id] ?? [])
                    .sorted { $0.direction == .recognition && $1.direction != .recognition }
                    .map(CardFile.Review.init)
            )
        }
        return CardFile(cards: entries, exportedAt: now)
    }

    public func importIntoFlashcards(_ file: CardFile, now: Date) async throws -> CardImportReport {
        let saved = try await expressions.all()
        var byKey: [String: Expression] = [:]
        for expression in saved.sorted(by: { $0.createdAt < $1.createdAt }) {
            let key = Self.key(expression.en)
            if byKey[key] == nil { byKey[key] = expression }
        }
        let enrolled = Set(try await cards.all().map(\.expressionID))

        var newExpressions: [Expression] = [], newCards: [ReviewCard] = []
        var added = 0, moved = 0, already = 0, skipped = 0
        var seen = Set<String>()
        for (index, entry) in file.cards.enumerated() {
            let text = entry.expression.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = entry.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.key(text)
            guard !text.isEmpty, !translation.isEmpty, seen.insert(key).inserted else { skipped += 1; continue }
            // A millisecond apart: new cards are introduced in file order.
            let movedIn = now.addingTimeInterval(Double(index) / 1_000)

            let expressionID: UUID
            if let existing = byKey[key] {
                guard !enrolled.contains(existing.id) else { already += 1; continue }
                expressionID = existing.id
                moved += 1
            } else {
                let expression = Expression(en: text, ru: translation, example: entry.example ?? "",
                                            synonyms: entry.synonyms ?? [], context: entry.context ?? "",
                                            createdAt: movedIn)
                newExpressions.append(expression)
                expressionID = expression.id
                added += 1
            }
            let restored = Dictionary((entry.review ?? []).map { ($0.direction, $0) }, uniquingKeysWith: { first, _ in first })
            for direction in CardDirection.allCases {
                newCards.append(restored[direction]?.card(for: expressionID)
                                ?? ReviewCard(expressionID: expressionID, direction: direction, due: movedIn))
            }
        }
        try await expressions.addAll(newExpressions)
        try await cards.saveAll(newCards)
        return CardImportReport(added: added, movedFromCaught: moved, alreadyInFlashcards: already, skipped: skipped)
    }

    /// Same matching as the study list's de-duplication (trimmed, case-insensitive), plus typographic
    /// apostrophes — "I’m" and "I'm" are one expression.
    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
    }
}
