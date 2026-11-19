//
//  LibraryUseCases.swift
//  EnglishHelper — Domain (use cases)
//
//  Study-list, history-read, and export orchestration over the repository / exporter ports.
//

import Foundation

// MARK: - Study list

public protocol StudyListUseCase: Sendable {
    func list() async throws -> [Expression]
    func add(_ expression: Expression) async throws
    func update(_ expression: Expression) async throws
    func delete(id: Expression.ID) async throws
    func setLearned(_ learned: Bool, id: Expression.ID) async throws
}

public struct StudyListInteractor: StudyListUseCase {
    private let repository: ExpressionRepository
    private let cards: (any ReviewCardRepository)?
    public init(repository: ExpressionRepository, cards: (any ReviewCardRepository)? = nil) {
        self.repository = repository
        self.cards = cards
    }

    public func list() async throws -> [Expression] { try await repository.all() }
    public func add(_ expression: Expression) async throws { try await repository.add(expression) }
    public func update(_ expression: Expression) async throws { try await repository.update(expression) }
    public func delete(id: Expression.ID) async throws {
        try await repository.delete(id: id)
        // Its flashcards go too. Best-effort: a leftover card is never shown (the queue is built from
        // the study list) and only costs a row.
        try? await cards?.delete(expressionID: id)
    }
    public func setLearned(_ learned: Bool, id: Expression.ID) async throws {
        try await repository.setLearned(learned, id: id)
    }
}

// MARK: - Save (create with enrichment)

public protocol SaveExpressionUseCase: Sendable {
    /// Expression CREATE from ANY flow: enrich (ru/example/synonyms) FIRST, then store.
    /// Returns the stored, enriched expression.
    func callAsFunction(en: String, knownRU: String?, context: String) async throws -> Expression
}

public struct SaveExpressionInteractor: SaveExpressionUseCase {
    private let enrich: EnrichExpressionUseCase
    private let repository: ExpressionRepository
    private let caught: CaughtPhrases
    /// Optional product analytics (nil = disabled, e.g. tests / mock boot). Events carry NO user content.
    private let analytics: (any AnalyticsTracking)?

    /// `cards`: what's in flashcards — a phrase there is saved into Caught again (and marked there);
    /// nil = nothing is (every saved phrase counts as Caught).
    public init(enrich: EnrichExpressionUseCase, repository: ExpressionRepository,
                cards: (any ReviewCardRepository)? = nil, analytics: (any AnalyticsTracking)? = nil) {
        self.enrich = enrich
        self.repository = repository
        self.caught = CaughtPhrases(expressions: repository, cards: cards)
        self.analytics = analytics
    }

    public func callAsFunction(en: String, knownRU: String? = nil, context: String = "") async throws -> Expression {
        // The very same phrase already in Caught: return it instead of a second row (and without a paid
        // enrich call). One in flashcards doesn't stop it — Caught then marks the new row (`CaughtPhrases`).
        if let existing = try await caught.inCaught(en) { return existing }
        let enrichment = try await enrich(EnrichInput(en: en, ru: knownRU))
        let expression = Expression(
            en: en,
            ru: enrichment.ru.isEmpty ? (knownRU ?? "") : enrichment.ru,
            example: enrichment.example,
            synonyms: enrichment.synonyms,
            context: context
        )
        try await repository.add(expression)
        analytics?.track(.expressionSaved)   // counts NEW cards only — the de-dup return above doesn't
        return expression
    }
}

// MARK: - History (read + delete)

public protocol RequestHistoryUseCase: Sendable {
    func recent(limit: Int) async throws -> [HistoryEntry]
    /// Remove one entry (user swipe-delete) — including its session recording, if it has one.
    func delete(_ entry: HistoryEntry) async throws
    /// Delete the session recordings no history entry refers to (a crash mid-session, a session of
    /// the in-memory fallback store, a failed save) — only the ones created before `createdBefore`
    /// (the launch), so a session recording right now keeps its file. Does NOTHING when history can't
    /// vouch for what it refers to: `usingFallbackStore` (the store on disk didn't open, history is
    /// an empty stand-in — the real rows still point at these files), an entry that can't be read, or
    /// a failed read. Deleting a recording is irreversible; leaving an orphan costs only disk space.
    func sweepOrphanedRecordings(createdBefore: Date, usingFallbackStore: Bool) async
}

public struct RequestHistoryInteractor: RequestHistoryUseCase {
    private let history: HistoryRepository
    /// Optional so mock/test boots without a recordings store still build; then audio cleanup is a no-op.
    private let recordings: (any SessionRecordingsManaging)?

    public init(history: HistoryRepository, recordings: (any SessionRecordingsManaging)? = nil) {
        self.history = history
        self.recordings = recordings
    }

    public func recent(limit: Int) async throws -> [HistoryEntry] {
        try await history.recent(limit: limit)
    }

    public func delete(_ entry: HistoryEntry) async throws {
        try await history.delete(id: entry.id)
        // Row is gone — the audio file (if any) must go with it, or it leaks forever.
        if let fileName = entry.result.recordingFileName {
            await recordings?.delete(fileName: fileName)
        }
    }

    public func sweepOrphanedRecordings(createdBefore: Date, usingFallbackStore: Bool) async {
        guard !usingFallbackStore, let recordings,
              let referenced = try? await history.referencedRecordings() else { return }
        await recordings.sweep(keeping: referenced, createdBefore: createdBefore)
    }
}

// MARK: - Translation cache admin (Settings: stats + clear)

public protocol TranslationCacheAdminUseCase: Sendable {
    func stats() async -> TranslationCacheStats
    func clear() async
}

public struct TranslationCacheAdminInteractor: TranslationCacheAdminUseCase {
    /// Optional so the app still builds without a cache (mock boot / tests) — then stats are zero and
    /// clear is a no-op.
    private let cache: (any TranslationCache)?
    public init(cache: (any TranslationCache)?) { self.cache = cache }

    public func stats() async -> TranslationCacheStats {
        await cache?.statistics() ?? TranslationCacheStats(entryCount: 0, hitCount: 0)
    }
    public func clear() async { await cache?.clear() }
}

// MARK: - Storage usage (Settings: disk space of cache / history / session audio)

public protocol StorageUsageUseCase: Sendable {
    func callAsFunction() async -> StorageUsage
}

public struct StorageUsageInteractor: StorageUsageUseCase {
    /// Optional so the app still builds without a reader (mock boot / tests) — then usage is zero.
    private let reader: (any StorageUsageReading)?
    public init(reader: (any StorageUsageReading)?) { self.reader = reader }

    public func callAsFunction() async -> StorageUsage {
        await reader?.usage() ?? .zero
    }
}

// MARK: - Export deck

public protocol ExportDeckUseCase: Sendable {
    /// Export the whole study list as a shareable deck file.
    func callAsFunction() async throws -> ExportedDeck
}

public struct ExportDeckInteractor: ExportDeckUseCase {
    private let repository: ExpressionRepository
    private let exporter: DeckExporting
    /// Optional product analytics (nil = disabled, e.g. tests / mock boot). Events carry NO user content.
    private let analytics: (any AnalyticsTracking)?

    public init(repository: ExpressionRepository, exporter: DeckExporting,
                analytics: (any AnalyticsTracking)? = nil) {
        self.repository = repository
        self.exporter = exporter
        self.analytics = analytics
    }

    public func callAsFunction() async throws -> ExportedDeck {
        let expressions = try await repository.all()
        guard !expressions.isEmpty else { throw ExportError.nothingToExport }
        let deck = try await exporter.export(expressions)
        analytics?.track(.deckExported)
        return deck
    }
}
