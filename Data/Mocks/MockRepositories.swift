//
//  MockRepositories.swift
//  EnglishHelper — Data (mock adapters)
//
//  In-memory actors. The SwiftData-backed implementations land in v1 (Step 2).
//

import Domain   // NB: no `import Foundation` — it would make `Expression` ambiguous with Foundation.Expression (Predicate).
import struct Foundation.Data   // just `Data` (for the translation cache) — avoids the `Expression` clash above.
import struct Foundation.UUID   // card ids (MockReviewCardRepository)
import struct Foundation.Date   // review-log times

public actor MockExpressionRepository: ExpressionRepository {
    private var items: [Expression]

    public init(seed: [Expression] = MockExpressionRepository.defaultSeed) {
        self.items = seed
    }

    public func all() async throws -> [Expression] {
        items.sorted { $0.createdAt > $1.createdAt }
    }

    public func add(_ expression: Expression) async throws {
        items.append(expression)
    }

    public func update(_ expression: Expression) async throws {
        guard let idx = items.firstIndex(where: { $0.id == expression.id }) else {
            throw RepositoryError.notFound
        }
        items[idx] = expression
    }

    public func delete(id: Expression.ID) async throws {
        items.removeAll { $0.id == id }
    }

    public func setLearned(_ learned: Bool, id: Expression.ID) async throws {
        guard let idx = items.firstIndex(where: { $0.id == id }) else {
            throw RepositoryError.notFound
        }
        items[idx].learned = learned
    }

    public func find(en: String) async throws -> Expression? {
        let key = MockExpressionRepository.normalizedKey(en)
        return items
            .sorted { $0.createdAt < $1.createdAt }
            .first { MockExpressionRepository.normalizedKey($0.en) == key }
    }

    public static let defaultSeed: [Expression] = [
        Expression(en: "I appreciate it", ru: "Я ценю это",
                   example: "Thanks for covering my shift — I really appreciate it.",
                   synonyms: ["I'm grateful", "thank you"],
                   context: "Тёплая благодарность."),
        Expression(en: "No worries at all", ru: "Ничего страшного",
                   example: "No worries at all, take your time.",
                   synonyms: ["it's fine", "don't mention it"],
                   context: "Снять неловкость.", learned: true),
    ]
}

public actor MockReviewCardRepository: ReviewCardRepository {
    private var cards: [UUID: ReviewCard]
    private var log: [ReviewLog]

    public init(seed: [ReviewCard] = [], logs: [ReviewLog] = []) {
        self.cards = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
        self.log = logs
    }

    public func all() async throws -> [ReviewCard] { Array(cards.values) }
    public func save(_ card: ReviewCard) async throws { cards[card.id] = card }
    public func delete(expressionID: UUID) async throws {
        cards = cards.filter { $0.value.expressionID != expressionID }
    }
    public func appendLog(_ entry: ReviewLog) async throws { log.append(entry) }
    public func logs(since date: Date) async throws -> [ReviewLog] { log.filter { $0.reviewedAt >= date } }
}

public actor MockHistoryRepository: HistoryRepository {
    private var entries: [HistoryEntry]

    public init(seed: [HistoryEntry] = []) {
        self.entries = seed
    }

    public func append(_ entry: HistoryEntry) async throws {
        entries.append(entry)
    }

    public func recent(limit: Int) async throws -> [HistoryEntry] {
        Array(entries.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    public func delete(id: HistoryEntry.ID) async throws {
        entries.removeAll { $0.id == id }
    }
}

/// In-memory `TranslationCache` for tests/previews — same contract as the SwiftData one without a store.
public actor MockTranslationCache: TranslationCache {
    private var store: [String: Data] = [:]
    private var hits = 0
    public init() {}
    public func value(forKey key: String) async -> Data? {
        guard let value = store[key] else { return nil }
        hits += 1
        return value
    }
    public func setValue(_ value: Data, forKey key: String) async { store[key] = value }
    public func statistics() async -> TranslationCacheStats {
        TranslationCacheStats(entryCount: store.count, hitCount: hits)
    }
    public func clear() async { store.removeAll(); hits = 0 }
}
