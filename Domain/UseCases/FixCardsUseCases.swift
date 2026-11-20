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
//  be stopped at any time and resumed later without sending an answered card twice; "start over" goes
//  through all of them again. Learning progress (the review cards) is untouched — only the texts change.
//
//  A phrase is DONE only when the model answered for it. What a failed request means is `RunFailure`'s
//  business (shared with the duplicates Check and cards from photos); here:
//  - the SERVICE doesn't answer (a timeout, an overload, a server error — after one more try): the run
//    stops with that error and the position stays BEFORE the batch, so the next run sends it again.
//    (Going on would walk the whole deck through a dead service and mark it all as passed.)
//  - the ANSWER leaves phrases out — unusable twice, the request rejected, or a card missing from a
//    good answer: the run goes on (one bad batch mustn't block the rest), those phrases get letter case
//    only and are remembered in the checkpoint (`unanswered`). The next run asks about each of them
//    ALONE, before anything else: answered → done; no answer even alone → GIVEN UP (`givenUp`: left as
//    it is, not sent again until "start over") — so a phrase the model can't take neither holds others
//    back nor is asked about forever.
//  - Nothing answers at all: `barrenLimit` requests in a row without one answer is not "this
//    request's trouble" — the run stops with the last error. And a phrase is given up only on
//    evidence that the model does answer: another request of the same run got its answer, or the
//    phrase went unanswered alone in two runs (`askedAlone` marks the first time). Until a run has
//    that evidence, phrases asked alone wait behind the batches.
//

import Foundation

/// Where the last run stopped: the last card it went past, in the run's order — and what became of the
/// phrases before it that the model gave no answer for.
public struct CardFixCheckpoint: Codable, Sendable, Equatable {
    public let createdAt: Date
    public let id: UUID
    /// Went unanswered: the next run asks about each alone.
    public let unanswered: Set<UUID>
    /// Those of `unanswered` already asked alone once, to no answer — while nothing showed that the
    /// model was answering at all. Once more, and they're given up.
    public let askedAlone: Set<UUID>
    /// No answer even alone: left as they are, not sent again until "start over".
    public let givenUp: Set<UUID>

    public init(createdAt: Date, id: UUID, unanswered: Set<UUID> = [], askedAlone: Set<UUID> = [],
                givenUp: Set<UUID> = []) {
        self.createdAt = createdAt
        self.id = id
        self.unanswered = unanswered
        self.askedAlone = askedAlone
        self.givenUp = givenUp
    }

    /// Checkpoints stored by earlier builds have only the position.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        id = try container.decode(UUID.self, forKey: .id)
        unanswered = try container.decodeIfPresent(Set<UUID>.self, forKey: .unanswered) ?? []
        askedAlone = try container.decodeIfPresent(Set<UUID>.self, forKey: .askedAlone) ?? []
        givenUp = try container.decodeIfPresent(Set<UUID>.self, forKey: .givenUp) ?? []
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
    /// Phrases the model answered for that needed no change — left as they were.
    public let unchanged: Int
    /// Phrases still without the model's answer after this run's requests (an unusable answer for their
    /// batch, a card left out of it): only their letter case was fixed, and the next run asks about
    /// each of them alone.
    public let failed: Int
    /// Phrases given up in this run — no answer even when asked about alone: left as they are.
    public let givenUp: Int

    public var fraction: Double { total == 0 ? 1 : Double(processed) / Double(total) }
    public var sentFraction: Double { total == 0 ? 1 : Double(sent) / Double(total) }

    /// `sent` defaults to `processed` (nothing waiting for an answer).
    public init(processed: Int, total: Int, changed: Int, failed: Int, sent: Int? = nil, givenUp: Int = 0,
                unchanged: Int = 0) {
        self.processed = processed
        self.sent = sent ?? processed
        self.total = total
        self.changed = changed
        self.unchanged = unchanged
        self.failed = failed
        self.givenUp = givenUp
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
    /// offline, the plan's limit, no API key, a service that doesn't answer, request after request
    /// without an answer, cancellation — keeping what's done and where it stopped.
    func callAsFunction(_ scope: FixScope, studiedLanguage: String, nativeLanguage: String, restart: Bool)
        -> AsyncThrowingStream<FixProgress, Error>
    /// Before phrases move from Caught into flashcards: the ones that lack something (`needsCompletion`
    /// — a translation, an example, synonyms or a note) are filled in by the model, in requests of
    /// `batchSize`, and stored; the rest are returned as they are, with no request. Returns all of
    /// them, in order. THROWS — and stores nothing more — when the model can't be reached, the plan's
    /// limit is spent, there's no key, or a phrase is still without an answer after a second request:
    /// the move must stop there, so a phrase never goes into flashcards without the model having seen
    /// it. (What it did answer for is stored, so the next try asks only about the rest.)
    func complete(_ expressions: [Expression], studiedLanguage: String, nativeLanguage: String) async throws
        -> [Expression]
    /// One card, on the user's request (the wand on a flashcard): it is ALWAYS sent to the model —
    /// complete or not — which fixes it and fills in what's missing, as a Fix cards run would; the
    /// result is stored and returned (equal to `expression` when the model changed nothing). Throws,
    /// changing nothing, when the model can't be reached, the plan's limit is spent, or it gives no
    /// usable answer for this card. The learning progress is never touched.
    func fix(_ expression: Expression, studiedLanguage: String, nativeLanguage: String) async throws -> Expression
}

public struct FixCardsInteractor: FixCardsUseCase {
    public static let batchSize = 20
    /// Requests in a row without a single answer after which it isn't "this request's trouble" any
    /// more: the run stops.
    public static let barrenLimit = 3

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
        let checkpoint = await progress.load(scope)
        return (all.filter { Self.isPending($0, checkpoint) }.count, all.count)
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
                        if Self.isPending(expression, allMark) { allLeft += 1 }
                        if Self.isIncomplete(expression) {
                            incomplete += 1
                            if Self.isPending(expression, incompleteMark) { incompleteLeft += 1 }
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
                    let start = await progress.load(scope)
                    let all = try await self.inFlashcards(scope)
                    // Left unanswered by an earlier run: each alone, first. Then the batches.
                    let again = all.filter { start?.unanswered.contains($0.id) ?? false }
                    var queue = again.map { Step(phrases: [$0], isAlone: true) }
                        + Self.chunks(Self.after(start, in: all), of: Self.batchSize).map { Step(phrases: $0, isAlone: false) }
                    var tally = Tally(start, keeping: Set(all.map(\.id)), again: again.count,
                                      total: queue.reduce(0) { $0 + $1.phrases.count })
                    /// Something in this run was answered: the model does answer.
                    var hasEvidence = false
                    /// Asked alone to no answer before there was evidence — given up as soon as there is.
                    var suspects: [UUID] = []
                    var barren = 0
                    var lastError: any Error = LLMError.invalidOutput("no card in the answer")
                    var isDeferred = false
                    continuation.yield(tally.progress())

                    var index = 0
                    while index < queue.count {
                        let step = queue[index]
                        if step.isAlone, !hasEvidence, barren >= Self.barrenLimit {
                            // Nothing has answered yet: the phrases' trouble, or the model's? The
                            // batches will tell — these wait behind them. No batches: stop.
                            let ahead = queue[index...]
                            guard !isDeferred, ahead.contains(where: { !$0.isAlone }) else { throw lastError }
                            queue = Array(queue[..<index]) + ahead.filter { !$0.isAlone } + ahead.filter(\.isAlone)
                            isDeferred = true
                            continue
                        }
                        index += 1
                        try Task.checkCancellation()
                        continuation.yield(tally.progress(sending: step.phrases.count))

                        let answer = try await Self.ask(llm, template, about: step.phrases)
                        var fixes: [String: FixCardItem] = [:]
                        switch answer {
                        case .success(let cards): fixes = cards
                        case .failure(let error): lastError = error
                        }
                        if step.phrases.contains(where: { fixes[$0.id.uuidString] != nil }) {
                            barren = 0
                            hasEvidence = true
                            suspects.forEach { tally.giveUp($0) }
                            suspects = []
                        } else {
                            barren += 1
                        }
                        for expression in step.phrases {
                            let fix = fixes[expression.id.uuidString]
                            if step.isAlone { tally.waiting -= 1 }
                            if fix != nil {
                                tally.answered(expression.id)
                            } else if !step.isAlone {
                                tally.unanswered.insert(expression.id)
                            } else if hasEvidence || tally.askedAlone.contains(expression.id) {
                                tally.giveUp(expression.id)
                            } else {
                                tally.askedAlone.insert(expression.id)
                                suspects.append(expression.id)
                            }
                            let fixed = Self.apply(fix, to: expression,
                                                   studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
                            if fixed != expression {
                                try await expressions.update(fixed)
                                tally.changed += 1
                            } else if fix != nil {
                                tally.unchanged += 1
                            }
                        }
                        // The position moves only with the batches; a phrase asked alone lies before it.
                        if !step.isAlone, let last = step.phrases.last { tally.position = (last.createdAt, last.id) }
                        tally.processed += step.phrases.count
                        if let checkpoint = tally.checkpoint { await progress.save(checkpoint, for: scope) }
                        continuation.yield(tally.progress())
                        if !step.isAlone, barren >= Self.barrenLimit { throw lastError }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Run

    /// One request of a run: a batch of phrases it hasn't reached, or one phrase an earlier run left
    /// unanswered, asked alone.
    private struct Step {
        let phrases: [Expression]
        let isAlone: Bool
    }

    /// What the run's next checkpoint and progress step are made of.
    private struct Tally {
        var position: (createdAt: Date, id: UUID)?
        var unanswered: Set<UUID>
        var askedAlone: Set<UUID>
        var givenUp: Set<UUID>
        var processed = 0, changed = 0, unchanged = 0, gaveUp = 0
        /// Phrases an earlier run left unanswered that this one hasn't asked about yet.
        var waiting: Int
        let total: Int

        /// Only phrases still in the scope are kept (not the deleted, nor — in "only incomplete" —
        /// those completed since).
        init(_ checkpoint: CardFixCheckpoint?, keeping ids: Set<UUID>, again: Int, total: Int) {
            position = checkpoint.map { ($0.createdAt, $0.id) }
            unanswered = (checkpoint?.unanswered ?? []).intersection(ids)
            askedAlone = (checkpoint?.askedAlone ?? []).intersection(unanswered)
            givenUp = (checkpoint?.givenUp ?? []).intersection(ids)
            waiting = again
            self.total = total
        }

        mutating func answered(_ id: UUID) {
            unanswered.remove(id)
            askedAlone.remove(id)
        }

        mutating func giveUp(_ id: UUID) {
            answered(id)
            givenUp.insert(id)
            gaveUp += 1
        }

        var checkpoint: CardFixCheckpoint? {
            position.map {
                CardFixCheckpoint(createdAt: $0.createdAt, id: $0.id, unanswered: unanswered,
                                  askedAlone: askedAlone, givenUp: givenUp)
            }
        }

        func progress(sending: Int = 0) -> FixProgress {
            FixProgress(processed: processed, total: total, changed: changed, failed: unanswered.count - waiting,
                        sent: processed + sending, givenUp: gaveUp, unchanged: unchanged)
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

    public func complete(_ expressions: [Expression], studiedLanguage: String, nativeLanguage: String) async throws
        -> [Expression] {
        let lacking = expressions.filter(Self.needsCompletion)
        guard !lacking.isEmpty else { return expressions }
        let template = FixCardsTemplate(studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
        var completed: [UUID: Expression] = [:]
        for start in stride(from: 0, to: lacking.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let batch = Array(lacking[start..<min(start + Self.batchSize, lacking.count)])
            // Asked once more about whatever the first answer left out. (An unusable answer was
            // already asked for twice.)
            var waiting = batch
            for _ in 1...2 where !waiting.isEmpty {
                guard case .success(let fixes) = try await Self.ask(llm, template, about: waiting) else { break }
                for expression in waiting {
                    guard let fix = fixes[expression.id.uuidString] else { continue }
                    completed[expression.id] = try await store(fix, onto: expression, studiedLanguage: studiedLanguage,
                                                               nativeLanguage: nativeLanguage)
                }
                waiting = waiting.filter { completed[$0.id] == nil }
            }
            guard waiting.isEmpty else {
                throw LLMError.invalidOutput("no answer for \(waiting.count) of the phrases to complete")
            }
        }
        return expressions.map { completed[$0.id] ?? $0 }
    }

    public func fix(_ expression: Expression, studiedLanguage: String, nativeLanguage: String) async throws -> Expression {
        let template = FixCardsTemplate(studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
        // Asked for by hand, about one card: an answer without it is a failure, not "letter case only".
        guard case .success(let fixes) = try await Self.ask(llm, template, about: [expression]),
              let fix = fixes[expression.id.uuidString] else {
            throw LLMError.invalidOutput("no usable answer for the card")
        }
        return try await store(fix, onto: expression, studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
    }

    /// The card with the model's fix applied (`apply`), stored if anything changed.
    private func store(_ fix: FixCardItem?, onto expression: Expression, studiedLanguage: String,
                       nativeLanguage: String) async throws -> Expression {
        let fixed = Self.apply(fix, to: expression, studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
        if fixed != expression { try await expressions.update(fixed) }
        return fixed
    }

    /// What a phrase needs before it becomes flashcards: a translation, an example, synonyms or a note.
    public static func needsCompletion(_ expression: Expression) -> Bool {
        expression.ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isIncomplete(expression)
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

    /// Whether the next run would send `expression`: the last one hasn't reached it, or went past it
    /// without the model's answer.
    static func isPending(_ expression: Expression, _ checkpoint: CardFixCheckpoint?) -> Bool {
        isAfter(expression, checkpoint) || (checkpoint?.unanswered.contains(expression.id) ?? false)
    }

    static func chunks(_ expressions: [Expression], of size: Int) -> [[Expression]] {
        stride(from: 0, to: expressions.count, by: size).map {
            Array(expressions[$0..<min($0 + size, expressions.count)])
        }
    }

    /// Whether a run that stopped at `checkpoint` hasn't reached `expression` yet.
    static func isAfter(_ expression: Expression, _ checkpoint: CardFixCheckpoint?) -> Bool {
        guard let checkpoint else { return true }
        return (expression.createdAt, expression.id.uuidString) > (checkpoint.createdAt, checkpoint.id.uuidString)
    }

    /// The model's fixes for these phrases, by card id (a card it left out isn't there), or why there's
    /// no answer for this request (`RunFailure.answer` / `.rejected` — the next one may well go
    /// through). THROWS when the service doesn't answer (twice), or asking again can't help now.
    private static func ask(_ llm: LLMClient, _ template: FixCardsTemplate,
                            about batch: [Expression]) async throws -> Result<[String: FixCardItem], any Error> {
        let items = batch.map {
            FixCardItem(id: $0.id.uuidString, expression: $0.en, translation: $0.ru, example: $0.example,
                        synonyms: $0.synonyms, context: $0.context)
        }
        switch try await RunRequest.send({ try await llm.run(template, input: items) }) {
        case .answer(let result):
            return .success(Dictionary(result.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        case .none(let error, .service):
            throw error
        case .none(let error, _):
            return .failure(error)
        }
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
