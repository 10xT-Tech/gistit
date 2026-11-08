//
//  FixCardsUseCases.swift
//  EnglishHelper — Domain (use cases)
//
//  In flashcards → "Fix cards": goes through every phrase in flashcards and
//  - starts the phrase and its translation with a capital letter (here, deterministically);
//  - via the model (`FixCardsTemplate`, batches of `batchSize`): fixes grammar and spelling, gives a
//    single verb its infinitive marker and a single noun its article, fills in a missing example,
//    synonyms and usage note.
//  Cards go in a stable order (oldest first) and the position after each batch is kept
//  (`CardFixProgressStoring`), so a run of thousands of cards can be stopped at any time and resumed
//  later without sending a card twice; "start over" goes through all of them again. Learning progress
//  (the review cards) is untouched — only the texts change.
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

public protocol CardFixProgressStoring: Sendable {
    func load() async -> CardFixCheckpoint?
    func save(_ checkpoint: CardFixCheckpoint) async
    func reset() async
}

/// In-memory default (tests, previews, the stub boot).
public actor InMemoryCardFixProgressStore: CardFixProgressStoring {
    private var checkpoint: CardFixCheckpoint?
    public init(_ checkpoint: CardFixCheckpoint? = nil) { self.checkpoint = checkpoint }
    public func load() async -> CardFixCheckpoint? { checkpoint }
    public func save(_ checkpoint: CardFixCheckpoint) async { self.checkpoint = checkpoint }
    public func reset() async { checkpoint = nil }
}

/// Where a run stands.
public struct FixProgress: Sendable, Equatable {
    /// Phrases gone through in this run.
    public let processed: Int
    /// Phrases this run goes through.
    public let total: Int
    /// Phrases whose card changed.
    public let changed: Int
    /// Phrases left as they were because the model's answer for their batch was unusable.
    public let failed: Int

    public var fraction: Double { total == 0 ? 1 : Double(processed) / Double(total) }

    public init(processed: Int, total: Int, changed: Int, failed: Int) {
        self.processed = processed
        self.total = total
        self.changed = changed
        self.failed = failed
    }
}

public protocol FixCardsUseCase: Sendable {
    /// Phrases in flashcards the next run would go through (after where the last one stopped), and all.
    func remaining() async throws -> (left: Int, total: Int)
    /// Yields progress at the start and after every batch. Ends by throwing when going on can't help —
    /// offline, the plan's limit, no API key, cancellation — keeping what's done (and where it stopped).
    func callAsFunction(studiedLanguage: String, nativeLanguage: String, restart: Bool)
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

    public func remaining() async throws -> (left: Int, total: Int) {
        let all = try await inFlashcards()
        return (Self.after(await progress.load(), in: all).count, all.count)
    }

    public func callAsFunction(studiedLanguage: String, nativeLanguage: String, restart: Bool)
        -> AsyncThrowingStream<FixProgress, Error> {
        let llm = self.llm, expressions = self.expressions, progress = self.progress
        let template = FixCardsTemplate(studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if restart { await progress.reset() }
                    let todo = Self.after(await progress.load(), in: try await self.inFlashcards())
                    var processed = 0, changed = 0, failed = 0
                    continuation.yield(FixProgress(processed: 0, total: todo.count, changed: 0, failed: 0))
                    for start in stride(from: 0, to: todo.count, by: Self.batchSize) {
                        try Task.checkCancellation()
                        let batch = Array(todo[start..<min(start + Self.batchSize, todo.count)])
                        let fixes = try await Self.ask(llm, template, about: batch)
                        if fixes == nil { failed += batch.count }
                        for expression in batch {
                            let fixed = Self.apply(fixes?[expression.id.uuidString], to: expression)
                            if fixed != expression {
                                try await expressions.update(fixed)
                                changed += 1
                            }
                        }
                        if let last = batch.last {
                            await progress.save(CardFixCheckpoint(createdAt: last.createdAt, id: last.id))
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

    /// The phrases in flashcards, in the run's stable order: oldest first.
    private func inFlashcards() async throws -> [Expression] {
        let enrolled = Set(try await cards.all().map(\.expressionID))
        return try await expressions.all()
            .filter { enrolled.contains($0.id) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// The part of `all` after the checkpoint.
    static func after(_ checkpoint: CardFixCheckpoint?, in all: [Expression]) -> [Expression] {
        guard let checkpoint else { return all }
        return all.filter { ($0.createdAt, $0.id.uuidString) > (checkpoint.createdAt, checkpoint.id.uuidString) }
    }

    /// The model's fixes for a batch, by card id — one retry; nil when the answer is unusable twice
    /// (those cards still get their capital letters). Failures the next batch would hit too are thrown.
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

    /// The card with the model's fix (if any) and capital letters.
    static func apply(_ fix: FixCardItem?, to expression: Expression) -> Expression {
        var out = expression
        if let fix {
            out.en = fix.expression
            out.ru = fix.translation
            out.example = fix.example
            out.synonyms = fix.synonyms
            out.context = fix.context
        }
        out.en = capitalized(out.en)
        out.ru = capitalized(out.ru)
        return out
    }

    /// The first letter upper-cased ("to run" → "To run", "«привет»" → "«Привет»"); the rest untouched.
    public static func capitalized(_ text: String) -> String {
        guard let index = text.firstIndex(where: \.isLetter) else { return text }
        return text.replacingCharacters(in: index...index, with: text[index].uppercased())
    }
}
