//
//  FixCardsUseCases.swift
//  EnglishHelper — Domain (use cases)
//
//  In flashcards → "Fix cards": goes through every phrase in flashcards and
//  - writes every field in lower case — except the English pronoun "I" (I'm, I've, I'll, I'd), and
//    German nouns when German is studied (here, deterministically: `lettercase`);
//  - via the model (`FixCardsTemplate`, batches of `batchSize`): fixes grammar and spelling, gives a
//    single verb its infinitive marker and a single noun its article, fills in a missing example,
//    synonyms and usage note. A field the model returns empty keeps what the card had.
//  A run goes through every phrase in flashcards, or only the incomplete ones (`FixScope`): those
//  with an empty example, synonyms or note. Cards go in a stable order (oldest first) and the position
//  after each batch is kept per scope (`CardFixProgressStoring`), so a run of thousands of cards can
//  be stopped at any time and resumed later without sending a card twice; "start over" goes through
//  all of them again. Learning progress (the review cards) is untouched — only the texts change.
//

import Foundation

/// Where the last run stopped: the last card fixed, in the run's order.
public struct CardFixCheckpoint: Codable, Sendable, Equatable {
    public let createdAt: Date
    public let id: UUID

    public init(createdAt: Date, id: UUID) {
        self.createdAt = createdAt
        self.id = id
    }
}

/// Which phrases a run goes through.
public enum FixScope: String, Sendable, CaseIterable {
    /// Every phrase in flashcards.
    case all
    /// Only those with an empty example, synonyms or note.
    case incomplete
}

/// Where the last run of each scope stopped.
public protocol CardFixProgressStoring: Sendable {
    func load(_ scope: FixScope) async -> CardFixCheckpoint?
    func save(_ checkpoint: CardFixCheckpoint, for scope: FixScope) async
    func reset(_ scope: FixScope) async
}

/// In-memory default (tests, previews, the stub boot).
public actor InMemoryCardFixProgressStore: CardFixProgressStoring {
    private var checkpoints: [FixScope: CardFixCheckpoint]
    public init(_ checkpoints: [FixScope: CardFixCheckpoint] = [:]) { self.checkpoints = checkpoints }
    public func load(_ scope: FixScope) async -> CardFixCheckpoint? { checkpoints[scope] }
    public func save(_ checkpoint: CardFixCheckpoint, for scope: FixScope) async { checkpoints[scope] = checkpoint }
    public func reset(_ scope: FixScope) async { checkpoints[scope] = nil }
}

/// Where a run stands.
public struct FixProgress: Sendable, Equatable {
    /// Phrases gone through in this run (the model answered for them).
    public let processed: Int
    /// Phrases sent to the model so far — `processed` plus the batch waiting for its answer.
    public let sent: Int
    /// Phrases this run goes through.
    public let total: Int
    /// Phrases whose card changed.
    public let changed: Int
    /// Phrases left as they were because the model's answer for their batch was unusable.
    public let failed: Int

    public var fraction: Double { total == 0 ? 1 : Double(processed) / Double(total) }
    public var sentFraction: Double { total == 0 ? 1 : Double(sent) / Double(total) }

    /// `sent` defaults to `processed` (nothing waiting for an answer).
    public init(processed: Int, total: Int, changed: Int, failed: Int, sent: Int? = nil) {
        self.processed = processed
        self.sent = sent ?? processed
        self.total = total
        self.changed = changed
        self.failed = failed
    }
}

/// A scope's phrases: those the next run would go through (after where its last run stopped), and all.
public struct FixCounts: Sendable, Equatable {
    public let left: Int
    public let total: Int
    public init(left: Int, total: Int) {
        self.left = left
        self.total = total
    }
}

/// Reading the phrases before a run: how far, and — once every one is read — what each scope covers.
public struct FixSurvey: Sendable, Equatable {
    public let checked: Int
    public let total: Int
    public let all: FixCounts?
    public let incomplete: FixCounts?

    public var fraction: Double { total == 0 ? 0 : Double(checked) / Double(total) }

    public init(checked: Int, total: Int, all: FixCounts? = nil, incomplete: FixCounts? = nil) {
        self.checked = checked
        self.total = total
        self.all = all
        self.incomplete = incomplete
    }
}

public protocol FixCardsUseCase: Sendable {
    /// Phrases of the scope the next run would go through (after where its last run stopped), and all.
    func remaining(_ scope: FixScope) async throws -> (left: Int, total: Int)
    /// Reads the phrases in flashcards and counts what each scope's next run would cover — progress
    /// while reading.
    func survey() -> AsyncThrowingStream<FixSurvey, Error>
    /// Yields progress at the start and after every batch. Ends by throwing when going on can't help —
    /// offline, the plan's limit, no API key, cancellation — keeping what's done (and where it stopped).
    func callAsFunction(_ scope: FixScope, studiedLanguage: String, nativeLanguage: String, restart: Bool)
        -> AsyncThrowingStream<FixProgress, Error>
}

public struct FixCardsInteractor: FixCardsUseCase {
    public static let batchSize = 20

    private let llm: LLMClient
    private let expressions: ExpressionRepository
    private let cards: ReviewCardRepository
    private let progress: CardFixProgressStoring

    public init(llm: LLMClient, expressions: ExpressionRepository, cards: ReviewCardRepository,
                progress: CardFixProgressStoring = InMemoryCardFixProgressStore()) {
        self.llm = llm
        self.expressions = expressions
        self.cards = cards
        self.progress = progress
    }

    public func remaining(_ scope: FixScope) async throws -> (left: Int, total: Int) {
        let all = try await inFlashcards(scope)
        return (Self.after(await progress.load(scope), in: all).count, all.count)
    }

    public func survey() -> AsyncThrowingStream<FixSurvey, Error> {
        let expressions = self.expressions, cards = self.cards, progress = self.progress
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(FixSurvey(checked: 0, total: 0))
                    let enrolled = Set(try await cards.all().map(\.expressionID))
                    let studied = try await expressions.all().filter { enrolled.contains($0.id) }
                    let allMark = await progress.load(.all), incompleteMark = await progress.load(.incomplete)
                    var all = 0, allLeft = 0, incomplete = 0, incompleteLeft = 0
                    for (index, expression) in studied.enumerated() {
                        all += 1
                        if Self.isAfter(expression, allMark) { allLeft += 1 }
                        if Self.isIncomplete(expression) {
                            incomplete += 1
                            if Self.isAfter(expression, incompleteMark) { incompleteLeft += 1 }
                        }
                        if (index + 1) % 50 == 0, index + 1 < studied.count {
                            try Task.checkCancellation()
                            continuation.yield(FixSurvey(checked: index + 1, total: studied.count))
                            await Task.yield()
                        }
                    }
                    continuation.yield(FixSurvey(checked: studied.count, total: studied.count,
                                                 all: FixCounts(left: allLeft, total: all),
                                                 incomplete: FixCounts(left: incompleteLeft, total: incomplete)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func callAsFunction(_ scope: FixScope, studiedLanguage: String, nativeLanguage: String, restart: Bool)
        -> AsyncThrowingStream<FixProgress, Error> {
        let llm = self.llm, expressions = self.expressions, progress = self.progress
        let template = FixCardsTemplate(studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if restart { await progress.reset(scope) }
                    let todo = Self.after(await progress.load(scope), in: try await self.inFlashcards(scope))
                    var processed = 0, changed = 0, failed = 0
                    continuation.yield(FixProgress(processed: 0, total: todo.count, changed: 0, failed: 0))
                    for start in stride(from: 0, to: todo.count, by: Self.batchSize) {
                        try Task.checkCancellation()
                        let batch = Array(todo[start..<min(start + Self.batchSize, todo.count)])
                        continuation.yield(FixProgress(processed: processed, total: todo.count, changed: changed,
                                                       failed: failed, sent: processed + batch.count))
                        let fixes = try await Self.ask(llm, template, about: batch)
                        if fixes == nil { failed += batch.count }
                        for expression in batch {
                            let fixed = Self.apply(fixes?[expression.id.uuidString], to: expression,
                                                   studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
                            if fixed != expression {
                                try await expressions.update(fixed)
                                changed += 1
                            }
                        }
                        if let last = batch.last {
                            await progress.save(CardFixCheckpoint(createdAt: last.createdAt, id: last.id), for: scope)
                        }
                        processed += batch.count
                        continuation.yield(FixProgress(processed: processed, total: todo.count,
                                                       changed: changed, failed: failed))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Steps

    /// The scope's phrases in flashcards, in the run's stable order: oldest first.
    private func inFlashcards(_ scope: FixScope) async throws -> [Expression] {
        let enrolled = Set(try await cards.all().map(\.expressionID))
        return try await expressions.all()
            .filter { enrolled.contains($0.id) && (scope == .all || Self.isIncomplete($0)) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// An example, synonyms or a note is missing.
    public static func isIncomplete(_ expression: Expression) -> Bool {
        let blank = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return blank(expression.example) || expression.synonyms.allSatisfy(blank) || blank(expression.context)
    }

    /// The part of `all` after the checkpoint.
    static func after(_ checkpoint: CardFixCheckpoint?, in all: [Expression]) -> [Expression] {
        all.filter { isAfter($0, checkpoint) }
    }

    /// Whether a run that stopped at `checkpoint` hasn't reached `expression` yet.
    static func isAfter(_ expression: Expression, _ checkpoint: CardFixCheckpoint?) -> Bool {
        guard let checkpoint else { return true }
        return (expression.createdAt, expression.id.uuidString) > (checkpoint.createdAt, checkpoint.id.uuidString)
    }

    /// The model's fixes for a batch, by card id — one retry; nil when the answer is unusable twice
    /// (those cards still get their letter case fixed). Failures the next batch would hit too are thrown.
    private static func ask(_ llm: LLMClient, _ template: FixCardsTemplate,
                            about batch: [Expression]) async throws -> [String: FixCardItem]? {
        let items = batch.map {
            FixCardItem(id: $0.id.uuidString, expression: $0.en, translation: $0.ru, example: $0.example,
                        synonyms: $0.synonyms, context: $0.context)
        }
        for attempt in 1...2 {
            do {
                let result = try await llm.run(template, input: items)
                return Dictionary(result.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            } catch {
                guard CatchCardsFromPhotosInteractor.canGoOn(after: error) else { throw error }
                if attempt == 2 { return nil }
            }
        }
        return nil
    }

    /// The card with the model's fix (if any) — a field it left empty keeps what the card had — every
    /// field in lower case (see `lettercase`).
    static func apply(_ fix: FixCardItem?, to expression: Expression, studiedLanguage: String,
                      nativeLanguage: String) -> Expression {
        var out = expression
        if let fix {
            out.en = fix.expression                                  // never empty: `decode` drops those
            out.ru = fix.translation
            if !fix.example.isEmpty { out.example = fix.example }
            if !fix.synonyms.isEmpty { out.synonyms = fix.synonyms }
            if !fix.context.isEmpty { out.context = fix.context }
        }
        let studied = { (text: String) in lettercase(text, language: studiedLanguage) }
        let native = { (text: String) in lettercase(text, language: nativeLanguage) }
        out.en = studied(out.en)
        out.example = studied(out.example)
        out.synonyms = out.synonyms.map(studied)
        out.ru = native(out.ru)
        out.context = native(out.context)
        return out
    }

    /// Lower case — except the English pronoun "I" (with I'm, I've, I'll, I'd) in English text, and
    /// German text left as it is (its nouns are capitalised by spelling).
    /// "A Corkscrew" → "a corkscrew", "i'm tired" → "I'm tired", "Я ценю это" → "я ценю это".
    public static func lettercase(_ text: String, language: String) -> String {
        if language == "German" { return text }
        let lower = text.lowercased()
        guard language == "English" else { return lower }
        // Simple word boundaries: an apostrophe ends a word, so the "i" of "i'm" is found too.
        return lower.replacing(/\bi\b/.wordBoundaryKind(.simple)) { _ in "I" }
    }
}
