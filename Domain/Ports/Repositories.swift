//
//  Repositories.swift
//  EnglishHelper — Domain (ports)
//

import Foundation

/// CRUD for the curated study list. Concrete impl is SwiftData-backed (Data layer).
public protocol ExpressionRepository: Sendable {
    func all() async throws -> [Expression]
    func add(_ expression: Expression) async throws
    /// Many at once, stored in one go (a card-file import). Default: one by one.
    func addAll(_ expressions: [Expression]) async throws
    func update(_ expression: Expression) async throws
    func delete(id: Expression.ID) async throws
    /// Toggle the staging "learned" flag.
    func setLearned(_ learned: Bool, id: Expression.ID) async throws
    /// First existing expression whose `en` matches (case-insensitive, trimmed), or nil. Drives
    /// content-level de-duplication so the same phrase isn't stored twice.
    func find(en: String) async throws -> Expression?
}

/// Flashcards (`ReviewCard`, two per expression moved to flashcards) and the log of answers.
public protocol ReviewCardRepository: Sendable {
    func all() async throws -> [ReviewCard]
    /// Insert or update, matched by `id`.
    func save(_ card: ReviewCard) async throws
    /// Many at once, stored in one go (a card-file import). Default: one by one.
    func saveAll(_ cards: [ReviewCard]) async throws
    /// Remove an expression's cards (it left the study list). Its answers stay in the log.
    func delete(expressionID: UUID) async throws
    func appendLog(_ log: ReviewLog) async throws
    /// Answers given at or after `date`.
    func logs(since date: Date) async throws -> [ReviewLog]
}

public extension ReviewCardRepository {
    func saveAll(_ cards: [ReviewCard]) async throws {
        for card in cards { try await save(card) }
    }
}

public extension ExpressionRepository {
    func addAll(_ expressions: [Expression]) async throws {
        for expression in expressions { try await add(expression) }
    }

    /// Normalized key for content-level matching of an expression's `en`.
    static func normalizedKey(_ en: String) -> String {
        en.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Append + fetch of request history, plus explicit row removal (user swipe-delete). The log is
/// still append-only from the REQUEST side — nothing ever edits an entry in place.
public protocol HistoryRepository: Sendable {
    func append(_ entry: HistoryEntry) async throws
    /// Most-recent-first, capped at `limit`.
    func recent(limit: Int) async throws -> [HistoryEntry]
    /// Remove one entry. A missing id is a silent no-op (the row may already be pruned).
    func delete(id: HistoryEntry.ID) async throws
}

/// A persistent cache of completed TEXT-translation requests (Say it · How to say / What to say, and
/// Get it · Translate), so the exact same input isn't sent to the model twice — a repeat shows the
/// earlier result instantly. Keyed by `TranslationCacheKey` (kind + text + tone + languages) and stores
/// the typed result as JSON `Data`. Both sides are best-effort: a miss (or any error) just runs the
/// request. Distinct from `HistoryRepository`, which is a lossy, display-shaped log.
public protocol TranslationCache: Sendable {
    /// The cached result bytes for `key`, or nil on a miss. A non-nil return counts as a hit.
    func value(forKey key: String) async -> Data?
    /// Persist `value` under `key` (upsert — the newest result for a key wins).
    func setValue(_ value: Data, forKey key: String) async
    /// Current entry count + the running total of hits (reads served from the cache).
    func statistics() async -> TranslationCacheStats
    /// Empty the cache and reset the hit counter.
    func clear() async
}

/// Cache usage shown in Settings.
public struct TranslationCacheStats: Sendable, Equatable {
    /// How many results are currently stored.
    public let entryCount: Int
    /// How many times a request was served from the cache instead of the model.
    public let hitCount: Int
    public init(entryCount: Int, hitCount: Int) {
        self.entryCount = entryCount
        self.hitCount = hitCount
    }
}

/// How much disk the app's stored data occupies, split by kind (Settings). The DB-backed numbers
/// (cache, history) are CONTENT sums — SQLite's own overhead (indexes, WAL, free pages) can't be
/// attributed per table — while audio is the actual size of the recording files on disk.
public struct StorageUsage: Sendable, Equatable {
    /// Translation-cache payloads (keys + cached result JSON).
    public let cacheBytes: Int
    /// History rows (input text + result JSON; live sessions' audio is counted separately).
    public let historyBytes: Int
    /// Session-recording audio files.
    public let audioBytes: Int
    public var totalBytes: Int { cacheBytes + historyBytes + audioBytes }

    public init(cacheBytes: Int, historyBytes: Int, audioBytes: Int) {
        self.cacheBytes = cacheBytes
        self.historyBytes = historyBytes
        self.audioBytes = audioBytes
    }

    public static let zero = StorageUsage(cacheBytes: 0, historyBytes: 0, audioBytes: 0)
}

/// Reports the disk usage above. Concrete impl reads the SwiftData rows and the session-recordings
/// directory (Data layer); best-effort — any read error just contributes zero.
public protocol StorageUsageReading: Sendable {
    func usage() async -> StorageUsage
}

/// Builds the cache key for a text-translation request. Inputs that change the result must all be in
/// the key: the scenario `kind`, the (trimmed) input text, the `tone`/register (Say it only; nil for
/// Translate), both languages, and the model `tier` (a per-scenario Settings choice — switching the
/// model must not serve results produced by the other one). Case is preserved — case can change
/// meaning ("polish"/"Polish").
public enum TranslationCacheKey {
    public static func make(kind: RequestKind, input: String, tone: Register?,
                            studiedLanguage: String, nativeLanguage: String,
                            tier: ModelTier) -> String {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let toneKey = tone?.rawValue ?? "-"
        let tierKey = tier == .fast ? "fast" : "standard"
        // \u{1} (a control char) can't appear in user text, so fields can't collide.
        return [kind.rawValue, studiedLanguage, nativeLanguage, toneKey, tierKey, normalized].joined(separator: "\u{1}")
    }
}

/// Today's practice set (`PracticeDay`) — kept between sessions so a practice interrupted at any
/// point continues from where it stopped when Start is pressed again the same day.
public protocol PracticeDayStoring: Sendable {
    func load() async -> PracticeDay?
    func save(_ day: PracticeDay) async
}

/// In-memory default (tests, previews, the stub boot): forgets on relaunch.
public actor InMemoryPracticeDayStore: PracticeDayStoring {
    private var day: PracticeDay?
    public init(_ day: PracticeDay? = nil) { self.day = day }
    public func load() async -> PracticeDay? { day }
    public func save(_ day: PracticeDay) async { self.day = day }
}
