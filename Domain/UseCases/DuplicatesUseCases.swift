//
//  DuplicatesUseCases.swift
//  EnglishHelper — Domain (use cases)
//
//  Duplicates among the phrases in flashcards, and against them when a phrase moves in from Caught.
//  - Scan (on the device): phrases whose studied-language expressions share a `PhraseKey` — the same
//    words apart from letter case, "to" / articles, placeholders, brackets, punctuation and word forms
//    — form a LOOK-ALIKE group; groups the user called "not duplicates" stay hidden. Look-alike is not
//    the same ("fuck about" / "fuck somebody about"), so a group is a set of candidates, and what to
//    merge inside it is proposed separately:
//  - Exact duplicates (on the device, no model): the same expression (`PhraseKey` without lemmas) with
//    the same translation — a merge is proposed at once; a group made only of them needs no check.
//  - Check (the model, `DuplicatesTemplate`, batches of `batchSize` groups): the merges each group
//    needs — a duplicate (one expression, one meaning) or senses (the very same expression, several
//    meanings: one card, numbered "1) … 2) …") — with the card each makes; a card in none stays apart.
//  - Merge: the oldest phrase in flashcards stays with the merged texts (in lower case except "I", as
//    Fix cards writes them; a field left empty keeps its text); the others go. Each direction keeps
//    ONE card: for a duplicate the best-known one (its knowledge is proven), for several meanings the
//    least-known one (the card now asks for all of them). Answers stay in the log.
//

import Foundation

/// Phrases in flashcards that look alike.
public struct DuplicateGroup: Sendable, Identifiable, Equatable {
    /// The `PhraseKey` they share — stable while the group is on screen.
    public let key: String
    /// Oldest first.
    public let expressions: [Expression]
    /// Their cards, by expression id.
    public let cards: [UUID: [ReviewCard]]
    /// Exact duplicates among them, found on the device.
    public let exact: [DuplicateMerge]

    public var id: String { key }
    /// What "not duplicates" remembers: the members' ids — a new look-alike makes it a new group.
    public var memberID: String { Self.memberID(of: expressions.map(\.id)) }
    /// Every member is in one exact duplicate: nothing for the model to decide.
    public var isExactOnly: Bool { exact.count == 1 && exact[0].expressionIDs.count == expressions.count }

    public static func memberID(of expressionIDs: [UUID]) -> String {
        expressionIDs.map(\.uuidString).sorted().joined(separator: ",")
    }

    public init(key: String, expressions: [Expression], cards: [UUID: [ReviewCard]], exact: [DuplicateMerge] = []) {
        self.key = key
        self.expressions = expressions
        self.cards = cards
        self.exact = exact
    }
}

/// A proposed merge inside a look-alike group: which phrases, what they are, the card they'd make.
public struct DuplicateMerge: Sendable, Equatable, Identifiable {
    /// Two or more, oldest first.
    public let expressionIDs: [UUID]
    public let kind: DuplicateKind
    public let card: CardText
    /// Found on the device (the same expression with the same translation), not proposed by the model.
    public let isExact: Bool

    public var id: String { DuplicateGroup.memberID(of: expressionIDs) }

    public init(expressionIDs: [UUID], kind: DuplicateKind, card: CardText, isExact: Bool) {
        self.expressionIDs = expressionIDs
        self.kind = kind
        self.card = card
        self.isExact = isExact
    }
}

/// Reading the phrases: how far, and — once every one is read — the groups.
public struct DuplicateScanStep: Sendable, Equatable {
    public let checked: Int
    public let total: Int
    public let groups: [DuplicateGroup]?

    public var fraction: Double { total == 0 ? 0 : Double(checked) / Double(total) }

    public init(checked: Int, total: Int, groups: [DuplicateGroup]? = nil) {
        self.checked = checked
        self.total = total
        self.groups = groups
    }
}

/// The model's check: groups sent, groups answered, and the proposals of this step's batch.
public struct DuplicateCheckStep: Sendable, Equatable {
    public let sent: Int
    public let answered: Int
    public let total: Int
    /// Groups the model's answer was unusable for (they stay unchecked).
    public let failed: Int
    /// The merges the model proposes, by group key — an empty list: all of the group stays apart.
    public let proposals: [String: [DuplicateMerge]]

    public init(sent: Int, answered: Int, total: Int, failed: Int = 0, proposals: [String: [DuplicateMerge]] = [:]) {
        self.sent = sent
        self.answered = answered
        self.total = total
        self.failed = failed
        self.proposals = proposals
    }
}

/// Sets of phrases the user marked "not duplicates" (by `DuplicateGroup.memberID`).
public protocol DuplicateDismissalStoring: Sendable {
    func dismissed() async -> Set<String>
    func dismiss(_ memberID: String) async
}

/// In-memory default (tests, previews, the stub boot).
public actor InMemoryDuplicateDismissalStore: DuplicateDismissalStoring {
    private var ids: Set<String>
    public init(_ ids: Set<String> = []) { self.ids = ids }
    public func dismissed() async -> Set<String> { ids }
    public func dismiss(_ memberID: String) async { ids.insert(memberID) }
}

public protocol DuplicatesUseCase: Sendable {
    /// Reads the phrases in flashcards and groups the look-alikes, with their exact duplicates —
    /// progress while reading.
    func scan(studiedLanguage: String) -> AsyncThrowingStream<DuplicateScanStep, Error>
    /// The merges the model proposes for each group, in batches — progress as they're sent and
    /// answered. Ends by throwing when going on can't help (offline, the plan's limit, no API key,
    /// cancellation).
    func check(_ groups: [DuplicateGroup], studiedLanguage: String, nativeLanguage: String)
        -> AsyncThrowingStream<DuplicateCheckStep, Error>
    /// The merges for one set of phrases (a phrase from Caught and its look-alikes): exact duplicates
    /// on the device; otherwise the model's proposals.
    func proposals(for expressions: [Expression], studiedLanguage: String, nativeLanguage: String) async throws
        -> [DuplicateMerge]
    /// For each of `expressions`, the phrases in flashcards that look alike (only those with any).
    func lookAlikesInFlashcards(for expressions: [Expression], studiedLanguage: String) async throws
        -> [UUID: [Expression]]
    /// Merge the phrases into one card (see the file header).
    func merge(_ expressions: [Expression], into card: CardText, as kind: DuplicateKind,
               studiedLanguage: String, nativeLanguage: String) async throws
    /// "Not duplicates": this set of phrases isn't offered again (a new look-alike makes a new group).
    func dismiss(_ expressionIDs: [UUID]) async
}

public struct DuplicatesInteractor: DuplicatesUseCase {
    public static let batchSize = 10

    private let llm: LLMClient
    private let expressions: ExpressionRepository
    private let cards: ReviewCardRepository
    private let lemmatizer: any Lemmatizing
    private let dismissals: DuplicateDismissalStoring
    /// Keys already worked out — lemmatizing thousands of phrases on every move from Caught would be slow.
    private let keys = KeyCache()

    public init(llm: LLMClient, expressions: ExpressionRepository, cards: ReviewCardRepository,
                lemmatizer: any Lemmatizing = NoLemmatizer(),
                dismissals: DuplicateDismissalStoring = InMemoryDuplicateDismissalStore()) {
        self.llm = llm
        self.expressions = expressions
        self.cards = cards
        self.lemmatizer = lemmatizer
        self.dismissals = dismissals
    }

    // MARK: Scan

    public func scan(studiedLanguage: String) -> AsyncThrowingStream<DuplicateScanStep, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(DuplicateScanStep(checked: 0, total: 0))
                    await lemmatizer.prepare(language: studiedLanguage)
                    let (studied, byExpression) = try await self.inFlashcards()
                    let dismissed = await self.dismissals.dismissed()
                    var byKey: [String: [Expression]] = [:]
                    for (index, expression) in studied.enumerated() {
                        byKey[key(expression, studiedLanguage), default: []].append(expression)
                        if index % 200 == 199 {
                            try Task.checkCancellation()
                            continuation.yield(DuplicateScanStep(checked: index + 1, total: studied.count))
                            await Task.yield()
                        }
                    }
                    let groups = byKey
                        .filter { $0.value.count > 1 && !dismissed.contains(DuplicateGroup.memberID(of: $0.value.map(\.id))) }
                        .map { key, members in
                            DuplicateGroup(key: key, expressions: members,
                                           cards: Dictionary(uniqueKeysWithValues: members.map { ($0.id, byExpression[$0.id] ?? []) }),
                                           exact: Self.exactMerges(among: members, language: studiedLanguage))
                        }
                        .sorted { ($0.expressions[0].createdAt, $0.key) < ($1.expressions[0].createdAt, $1.key) }
                    continuation.yield(DuplicateScanStep(checked: studied.count, total: studied.count, groups: groups))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The phrases in flashcards, oldest first, and every card by expression.
    private func inFlashcards() async throws -> ([Expression], [UUID: [ReviewCard]]) {
        let byExpression = Dictionary(grouping: try await cards.all(), by: \.expressionID)
        let studied = try await expressions.all()
            .filter { byExpression[$0.id] != nil }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        return (studied, byExpression)
    }

    public func lookAlikesInFlashcards(for candidates: [Expression], studiedLanguage: String) async throws
        -> [UUID: [Expression]] {
        await lemmatizer.prepare(language: studiedLanguage)
        let (studied, _) = try await inFlashcards()
        var byKey: [String: [Expression]] = [:]
        for expression in studied {
            byKey[key(expression, studiedLanguage), default: []].append(expression)
        }
        var found: [UUID: [Expression]] = [:]
        for candidate in candidates {
            let alike = (byKey[key(candidate, studiedLanguage)] ?? []).filter { $0.id != candidate.id }
            if !alike.isEmpty { found[candidate.id] = alike }
        }
        return found
    }

    private func key(_ expression: Expression, _ language: String) -> String {
        keys.key(for: expression, language: language) {
            PhraseKey.make(expression.en, language: language, lemmatizer: lemmatizer)
        }
    }

    // MARK: Exact duplicates

    /// The same expression (`PhraseKey` without lemmas: "to hit the roof" = "Hit the roof!", but not
    /// "hitting the roof") with the same translation (letter case, "ё", punctuation and spacing aside):
    /// one merge per such set, its card the oldest one's texts with the empty fields filled from the rest.
    public static func exactMerges(among members: [Expression], language: String) -> [DuplicateMerge] {
        let ordered = members.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        var sets: [String: [Expression]] = [:]
        var order: [String] = []
        for expression in ordered {
            let key = PhraseKey.make(expression.en, language: language) + "|" + Self.translationKey(expression.ru)
            if sets[key] == nil { order.append(key) }
            sets[key, default: []].append(expression)
        }
        return order.compactMap { key in
            guard let same = sets[key], same.count > 1 else { return nil }
            let first = same[0]
            let filled = { (field: (Expression) -> String) in same.map(field).first { !$0.isEmpty } ?? "" }
            var synonyms: [String] = []
            for synonym in same.flatMap(\.synonyms) where !synonyms.contains(where: { $0.lowercased() == synonym.lowercased() }) {
                synonyms.append(synonym)
            }
            return DuplicateMerge(expressionIDs: same.map(\.id), kind: .duplicate,
                                  card: CardText(expression: first.en, translation: first.ru, example: filled(\.example),
                                                 synonyms: Array(synonyms.prefix(4)), context: filled(\.context)),
                                  isExact: true)
        }
    }

    private static func translationKey(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .replacing(/[^\p{L}\p{N}]+/, with: " ")
            .split(separator: " ").joined(separator: " ")
    }

    // MARK: Check

    public func check(_ groups: [DuplicateGroup], studiedLanguage: String, nativeLanguage: String)
        -> AsyncThrowingStream<DuplicateCheckStep, Error> {
        let llm = self.llm
        let template = DuplicatesTemplate(studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var sent = 0, answered = 0, failed = 0
                    continuation.yield(DuplicateCheckStep(sent: 0, answered: 0, total: groups.count))
                    for start in stride(from: 0, to: groups.count, by: Self.batchSize) {
                        try Task.checkCancellation()
                        let batch = Array(groups[start..<min(start + Self.batchSize, groups.count)])
                        sent += batch.count
                        continuation.yield(DuplicateCheckStep(sent: sent, answered: answered, total: groups.count,
                                                              failed: failed))
                        let verdicts = try await Self.ask(llm, template,
                                                          about: batch.map { Self.item($0.key, $0.expressions) })
                        answered += batch.count
                        var proposals: [String: [DuplicateMerge]] = [:]
                        for group in batch {
                            if let verdict = verdicts?[group.key] {
                                proposals[group.key] = Self.merges(verdict, among: group.expressions)
                            }
                        }
                        failed += batch.count - proposals.count
                        continuation.yield(DuplicateCheckStep(sent: sent, answered: answered, total: groups.count,
                                                              failed: failed, proposals: proposals))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func proposals(for group: [Expression], studiedLanguage: String, nativeLanguage: String) async throws
        -> [DuplicateMerge] {
        let exact = Self.exactMerges(among: group, language: studiedLanguage)
        if !exact.isEmpty { return exact }
        let template = DuplicatesTemplate(studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
        let id = DuplicateGroup.memberID(of: group.map(\.id))
        let result = try await llm.run(template, input: [Self.item(id, group)])
        guard let verdict = result.groups.first(where: { $0.id == id }) ?? result.groups.first else {
            throw LLMError.invalidOutput("no answer for the group")
        }
        return Self.merges(verdict, among: group)
    }

    private static func item(_ id: String, _ members: [Expression]) -> DuplicateGroupItem {
        DuplicateGroupItem(id: id, cards: members.map {
            FixCardItem(id: $0.id.uuidString, expression: $0.en, translation: $0.ru, example: $0.example,
                        synonyms: $0.synonyms, context: $0.context)
        })
    }

    /// The model's merges as proposals: only the group's own phrases, each in one merge at most, two or
    /// more per merge, oldest first.
    public static func merges(_ verdict: DuplicateVerdict, among members: [Expression]) -> [DuplicateMerge] {
        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id.uuidString, $0) })
        var used = Set<String>()
        return verdict.merges.compactMap { answer in
            let ids = answer.ids.filter { byID[$0] != nil && !used.contains($0) }
            guard ids.count > 1 else { return nil }
            used.formUnion(ids)
            let ordered = ids.compactMap { byID[$0] }
                .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            return DuplicateMerge(expressionIDs: ordered.map(\.id), kind: answer.verdict, card: answer.card, isExact: false)
        }
    }

    /// The model's answers for a batch, by group id — one retry; nil when the answer is unusable twice.
    /// Failures the next batch would hit too are thrown.
    private static func ask(_ llm: LLMClient, _ template: DuplicatesTemplate,
                            about items: [DuplicateGroupItem]) async throws -> [String: DuplicateVerdict]? {
        for attempt in 1...2 {
            do {
                let result = try await llm.run(template, input: items)
                return Dictionary(result.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            } catch {
                guard CatchCardsFromPhotosInteractor.canGoOn(after: error) else { throw error }
                if attempt == 2 { return nil }
            }
        }
        return nil
    }

    // MARK: Merge

    public func merge(_ group: [Expression], into card: CardText, as kind: DuplicateKind,
                      studiedLanguage: String, nativeLanguage: String) async throws {
        let ids = Set(group.map(\.id))
        guard ids.count > 1 else { return }
        let groupCards = try await cards.all().filter { ids.contains($0.expressionID) }
        let enrolled = Set(groupCards.map(\.expressionID))
        let ordered = group.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        guard let keep = Self.kept(of: group, enrolled: enrolled) else { return }

        try await expressions.update(Self.texts(card, onto: keep, studiedLanguage: studiedLanguage,
                                                nativeLanguage: nativeLanguage))
        var kept: [ReviewCard] = []
        for direction in CardDirection.allCases {
            // The kept phrase's own card first: it wins a tie.
            let candidates = groupCards.filter { $0.direction == direction }
                .sorted { ($0.expressionID == keep.id ? 0 : 1) < ($1.expressionID == keep.id ? 0 : 1) }
            if let chosen = Self.pick(candidates, for: kind) {
                kept.append(ReviewCard(id: chosen.id, expressionID: keep.id, direction: direction, state: chosen.state,
                                       due: chosen.due, stability: chosen.stability, difficulty: chosen.difficulty,
                                       step: chosen.step, reps: chosen.reps, lapses: chosen.lapses,
                                       lastReview: chosen.lastReview, firstReview: chosen.firstReview))
            }
        }
        for id in enrolled { try await cards.delete(expressionID: id) }
        try await cards.saveAll(kept)
        for other in ordered where other.id != keep.id { try await expressions.delete(id: other.id) }
    }

    /// The phrase a merge of `group` keeps: the oldest one in flashcards (the oldest of all if none is).
    public static func kept(of group: [Expression], enrolled: Set<UUID>) -> Expression? {
        let ordered = group.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        return ordered.first { enrolled.contains($0.id) } ?? ordered.first
    }

    /// The merged texts on the kept phrase — a field left empty keeps its text — in the letter case
    /// Fix cards writes.
    static func texts(_ card: CardText, onto expression: Expression, studiedLanguage: String,
                      nativeLanguage: String) -> Expression {
        var out = expression
        if !card.expression.isEmpty { out.en = card.expression }
        if !card.translation.isEmpty { out.ru = card.translation }
        if !card.example.isEmpty { out.example = card.example }
        if !card.synonyms.isEmpty { out.synonyms = card.synonyms }
        if !card.context.isEmpty { out.context = card.context }
        let studied = { (text: String) in FixCardsInteractor.lettercase(text, language: studiedLanguage) }
        let native = { (text: String) in FixCardsInteractor.lettercase(text, language: nativeLanguage) }
        out.en = studied(out.en)
        out.example = studied(out.example)
        out.synonyms = out.synonyms.map(studied)
        out.ru = native(out.ru)
        out.context = native(out.context)
        return out
    }

    /// The card a direction keeps: among the ones already answered, the best known for a duplicate,
    /// the least known for several meanings; a new card only if none was answered.
    public static func pick(_ candidates: [ReviewCard], for kind: DuplicateKind) -> ReviewCard? {
        let answered = candidates.filter { $0.state != .new }
        guard !answered.isEmpty else { return candidates.first }
        let strength = { (card: ReviewCard) in (card.state == .review ? 1 : 0, card.stability, card.reps) }
        switch kind {
        case .duplicate:
            return answered.max { strength($0) < strength($1) }
        case .senses:
            return answered.min { strength($0) < strength($1) }
        }
    }

    // MARK: Not duplicates

    public func dismiss(_ expressionIDs: [UUID]) async {
        guard expressionIDs.count > 1 else { return }
        await dismissals.dismiss(DuplicateGroup.memberID(of: expressionIDs))
    }
}

/// `PhraseKey`s by phrase, recomputed when the phrase's text or the language changes.
private final class KeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: (text: String, language: String, key: String)] = [:]

    func key(for expression: Expression, language: String, make: () -> String) -> String {
        if let cached = lock.withLock({ keys[expression.id] }), cached.text == expression.en, cached.language == language {
            return cached.key
        }
        let key = make()
        lock.withLock { keys[expression.id] = (expression.en, language, key) }
        return key
    }
}
