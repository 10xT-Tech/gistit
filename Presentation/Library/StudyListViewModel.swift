//
//  StudyListViewModel.swift
//  EnglishHelper — Presentation
//
//  The saved expressions, in one of two scopes:
//  - Caught: saved from Say it / Get it / See it or caught here (generated from a phrase, or from
//    photos) and not in flashcards yet — delete, move one or all into flashcards, copy as cards,
//    export every saved expression to an AlgoApp .xml / Anki deck. A phrase that looks like one
//    already in flashcards (`PhraseKey`) asks first: merge into it (the model writes the merged card),
//    move it as a phrase of its own, or not; "Move all" can leave the look-alikes on the list.
//  - In flashcards: the expressions being learned — delete (with their cards); export them to a card
//    file with their progress, import a card file straight into flashcards; Fix cards and Find
//    duplicates open their sheets.
//

import Foundation
import Domain

@MainActor
@Observable
public final class StudyListViewModel {
    public enum Phase: Equatable { case loading, loaded, empty, failed }
    public enum Scope: Sendable { case caught, studying }

    public let scope: Scope

    public private(set) var phase: Phase = .loading
    public private(set) var expressions: [Domain.Expression] = []   // Domain.* avoids Foundation.Expression
    /// The search field: filters the list by any field of the card.
    public var searchText = ""
    /// What the list shows: every expression, or the ones matching the search.
    public var visibleExpressions: [Domain.Expression] {
        guard isSearching else { return expressions }
        return expressions.filter { $0.matches(searchText) }
    }
    public var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public private(set) var errorMessage: String?

    // Add form
    public var showAddSheet = false
    public var newEnglish = ""
    public var newContext = ""
    public private(set) var isAdding = false
    public private(set) var addError: String?

    // Export
    public private(set) var exportedDeck: ExportedDeck?
    public private(set) var exportError: String?

    /// A failed delete / move, surfaced without flipping the whole list to `.failed`.
    public private(set) var actionError: String?
    /// The action stopped at the free plan's limit: the message offers the subscription (a sheet with
    /// "Subscribe", not the plain alert).
    public private(set) var actionNeedsSubscription = false

    public enum ExportFormat: CaseIterable, Sendable {
        case algoApp, anki
        public var title: String {
            switch self {
            case .algoApp: "AlgoApp (.xml)"
            case .anki: "Anki (.txt)"
            }
        }
    }

    public private(set) var playingID: UUID?
    /// In flashcards: each expression's cards (its learning status and review counts).
    public private(set) var cardsByExpression: [UUID: [ReviewCard]] = [:]
    /// In flashcards: the phrases each one is marked "not duplicates" with.
    private var notDuplicateIDs: [UUID: [UUID]] = [:]

    /// "Delete all" (Caught) asks first.
    public var showDeleteAllConfirmation = false
    /// Caught phrases a check found to look like phrases already in flashcards: their rows carry a
    /// mark, and "Move new" leaves them here. Filled by a single move that came back to ask and by the
    /// check before "Move all" (which goes through the whole list, so it replaces the set).
    public private(set) var lookAlikeIDs: Set<UUID> = []

    /// Caught phrases that ARE in flashcards (the very same phrase, `Expression.matchKey`) — a subset of
    /// `lookAlikeIDs`.
    public private(set) var inFlashcardsIDs: Set<UUID> = []
    /// Whether the marks are worked out for the rows shown (until then no row is called new).
    public private(set) var marksKnown = false

    /// Whether a check found this caught phrase to look like one already in flashcards.
    public func isLookAlike(_ expression: Domain.Expression) -> Bool { lookAlikeIDs.contains(expression.id) }

    /// What a Caught row says about flashcards: the very same phrase is there, one like it is, or it's new.
    public enum CaughtMark: Equatable { case inFlashcards, lookAlike, new }

    /// The mark of a Caught row — nil on In flashcards, or before the check answered.
    public func mark(_ expression: Domain.Expression) -> CaughtMark? {
        guard scope == .caught, marksKnown || duplicates == nil else { return nil }
        if inFlashcardsIDs.contains(expression.id) { return .inFlashcards }
        if lookAlikeIDs.contains(expression.id) { return .lookAlike }
        return .new
    }
    /// A caught phrase that looks like one already in flashcards, being moved: it goes in only by a
    /// merge, worked out at once and put to the user — Merge, or Add as a separate card.
    public struct MergeOffer: Identifiable, Equatable {
        public enum Stage: Equatable {
            /// The merged card is being worked out (exact on the device, else the model).
            case preparing
            /// The card the merge makes, to confirm.
            case ready(DuplicateMerge)
            /// The model couldn't answer: try again, or add the phrase as a card of its own.
            case failed(String, needsSubscription: Bool)
        }
        public let caught: Domain.Expression
        public let existing: [Domain.Expression]
        public var stage: Stage
        public var id: UUID { caught.id }
    }
    /// The merge sheet on screen while non-nil.
    public var mergeOffer: MergeOffer?
    /// A confirmed merge is being written.
    public private(set) var isMerging = false
    /// Caught → From photos, on screen while non-nil.
    public var catchSession: CatchFromPhotosViewModel?
    /// The "Fix cards" sheet on screen while non-nil.
    public var fixSession: FixCardsViewModel?
    /// The "Find duplicates" sheet on screen while non-nil.
    public var duplicatesSession: DuplicatesViewModel?
    /// A card-file import is running.
    public private(set) var isImporting = false
    /// The outcome of the last import, for an alert.
    public private(set) var importMessage: String?

    private let studyList: any StudyListUseCase
    private let saveExpression: any SaveExpressionUseCase
    private let exportAlgoApp: any ExportDeckUseCase
    private let exportAnki: any ExportDeckUseCase
    private let pronounce: any PlayPronunciationUseCase
    private let isConfigured: Bool
    private let flashcards: (any FlashcardsUseCase)?
    private let catchFromPhotos: (any CatchCardsFromPhotosUseCase)?
    private let cardTransfer: (any CardTransferUseCase)?
    private let fixCards: (any FixCardsUseCase)?
    private let duplicates: (any DuplicatesUseCase)?
    private let studiedLanguage: () -> String
    private let nativeLanguage: () -> String
    private var playTask: Task<Void, Never>?
    private var bulkMoveTask: Task<Void, Never>?

    /// In flashcards → the card view's wand: fixing one card with the model (nil when Fix cards isn't wired).
    public let cardFix: CardFixModel?

    /// Caught phrases being moved one by one right now (completed by the model if they lack fields,
    /// then given their cards): their rows show it, and leave the list once moved.
    public private(set) var movingIDs: Set<UUID> = []
    /// "Move all" / "Move new" under way: how many of how many have moved.
    public struct BulkMove: Equatable, Sendable {
        public let done: Int
        public let total: Int
    }
    public private(set) var bulkMove: BulkMove?
    public func isMoving(_ expression: Domain.Expression) -> Bool { movingIDs.contains(expression.id) }

    public init(
        studyList: any StudyListUseCase,
        saveExpression: any SaveExpressionUseCase,
        exportAlgoApp: any ExportDeckUseCase,
        exportAnki: any ExportDeckUseCase,
        pronounce: any PlayPronunciationUseCase,
        isConfigured: Bool,
        flashcards: (any FlashcardsUseCase)? = nil,
        catchFromPhotos: (any CatchCardsFromPhotosUseCase)? = nil,
        cardTransfer: (any CardTransferUseCase)? = nil,
        fixCards: (any FixCardsUseCase)? = nil,
        duplicates: (any DuplicatesUseCase)? = nil,
        scope: Scope = .caught,
        studiedLanguage: @escaping () -> String = { StudiedLanguage.current.promptName },
        nativeLanguage: @escaping () -> String = { TargetLanguage.current.promptName }
    ) {
        self.studyList = studyList
        self.saveExpression = saveExpression
        self.exportAlgoApp = exportAlgoApp
        self.exportAnki = exportAnki
        self.pronounce = pronounce
        self.isConfigured = isConfigured
        self.flashcards = flashcards
        self.catchFromPhotos = catchFromPhotos
        self.cardTransfer = cardTransfer
        self.fixCards = fixCards
        self.cardFix = fixCards.map {
            CardFixModel(fixCards: $0, studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
        }
        self.duplicates = duplicates
        self.scope = scope
        self.studiedLanguage = studiedLanguage
        self.nativeLanguage = nativeLanguage
    }

    public var canAdd: Bool { !newEnglish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var needsAPIKey: Bool { !isConfigured }

    public func load() async {
        // Spinner only before the first answer: a known-empty list reloading (e.g. uncovered under a
        // tab swipe) keeps its empty state instead of flashing "Loading…".
        if expressions.isEmpty, phase != .empty { phase = .loading }
        do {
            let all = try await studyList.list()
            let cards = try await flashcards?.enrolledCards() ?? []
            let enrolled = Set(cards.map(\.expressionID))
            let items = all.filter { enrolled.contains($0.id) == (scope == .studying) }
            cardsByExpression = scope == .studying ? Dictionary(grouping: cards, by: \.expressionID) : [:]
            var links: [UUID: [UUID]] = [:]
            if scope == .studying, let pairs = try? await duplicates?.notDuplicates() {
                for pair in pairs {
                    links[pair.first, default: []].append(pair.second)
                    links[pair.second, default: []].append(pair.first)
                }
            }
            notDuplicateIDs = links
            expressions = items
            phase = items.isEmpty ? .empty : .loaded
            if scope == .caught { await markCaught(items) }
        } catch {
            errorMessage = Loc.t("Не удалось загрузить список.", "Couldn't load the list.")
            phase = .failed
        }
    }

    public func add() {
        let english = newEnglish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !english.isEmpty, !isAdding else { return }
        let context = newContext.trimmingCharacters(in: .whitespacesAndNewlines)
        // The very same phrase already in Caught isn't added again — say so instead of closing quietly.
        if scope == .caught,
           let existing = expressions.first(where: { Domain.Expression.matchKey($0.en) == Domain.Expression.matchKey(english) }) {
            addError = Loc.t("«\(existing.en)» уже есть в «Пойманных».", "\"\(existing.en)\" is already in Caught.",
                             "« \(existing.en) » est déjà dans « Capturées ».", "«\(existing.en)» ya está en «Atrapadas».",
                             "„\(existing.en)“ ist schon in „Eingefangen“.", "«\(existing.en)» è già in «Catturate».")
            return
        }
        isAdding = true
        addError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.saveExpression(en: english, knownRU: nil, context: context)
                self.resetAddForm()
                self.isAdding = false
                self.showAddSheet = false
                await self.load()
            } catch {
                self.isAdding = false
                self.addError = presentableError(error).message
            }
        }
    }

    /// Clear the add-sheet inputs + error so a Cancel (or a successful save) doesn't leave stale text
    /// and a stale error for the next time the sheet opens.
    public func resetAddForm() {
        newEnglish = ""
        newContext = ""
        addError = nil
    }

    public func delete(_ expression: Domain.Expression) {
        guard let index = expressions.firstIndex(where: { $0.id == expression.id }) else { return }
        let removed = expressions.remove(at: index)
        let wasLoaded = phase
        if expressions.isEmpty { phase = .empty }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.studyList.delete(id: expression.id)
            } catch {
                // Persisted delete failed → re-insert so the visible list can't diverge from the store.
                self.expressions.insert(removed, at: min(index, self.expressions.count))
                self.phase = wasLoaded
                self.actionError = Loc.t("Не удалось удалить. Попробуйте ещё раз.",
                                         "Couldn't delete. Try again.")
            }
        }
    }

    /// Caught → "Delete all": every phrase in the list goes (the list empties at once). If any delete
    /// fails, the list is read again and says so.
    public func deleteAll() {
        guard scope == .caught, !expressions.isEmpty else { return }
        let removing = expressions
        expressions = []
        phase = .empty
        Task { [weak self] in
            guard let self else { return }
            var failed = false
            for expression in removing {
                do { try await self.studyList.delete(id: expression.id) } catch { failed = true }
            }
            if failed {
                await self.load()
                self.actionError = Loc.t("Не удалось удалить часть фраз. Попробуйте ещё раз.",
                                         "Couldn't delete some phrases. Try again.")
            }
        }
    }

    /// Move one phrase into flashcards. A NEW one moves at once — completed by the model first if it
    /// lacks fields (`FixCardsUseCase.complete`); the row stays (showing it's moving) until it IS in
    /// flashcards, and a failure — offline, the plan's limit, no answer — stops it and says why. One that
    /// looks like a phrase already there goes in only by a merge: the merged card is worked out at once
    /// and put to the user (`mergeOffer`) — Merge, or Add as a separate card.
    public func moveToFlashcards(_ expression: Domain.Expression) {
        guard flashcards != nil, bulkMove == nil, mergeOffer == nil, !movingIDs.contains(expression.id),
              expressions.contains(where: { $0.id == expression.id }) else { return }
        movingIDs.insert(expression.id)
        let duplicates = self.duplicates, language = studiedLanguage()
        Task { [weak self] in
            guard let self else { return }
            if let duplicates,
               let existing = (try? await duplicates.lookAlikesInFlashcards(for: [expression], studiedLanguage: language))?[expression.id] {
                self.movingIDs.remove(expression.id)
                self.lookAlikeIDs.insert(expression.id)      // the row is marked from now on
                self.offerMerge(of: expression, into: existing)
                return
            }
            await self.moveOne(expression)
        }
    }

    /// Open the merge sheet and work the merged card out.
    private func offerMerge(of caught: Domain.Expression, into existing: [Domain.Expression]) {
        guard let duplicates else { return }
        mergeOffer = MergeOffer(caught: caught, existing: existing, stage: .preparing)
        let studied = studiedLanguage(), native = nativeLanguage()
        Task { [weak self] in
            let stage: MergeOffer.Stage
            do {
                stage = .ready(try await duplicates.caughtMerge(caught, into: existing,
                                                                studiedLanguage: studied, nativeLanguage: native))
            } catch {
                let presentable = presentableError(error)
                stage = .failed(presentable.message, needsSubscription: presentable.needsSubscription)
            }
            guard let self, self.mergeOffer?.id == caught.id else { return }    // closed meanwhile
            self.mergeOffer?.stage = stage
        }
    }

    /// The merge sheet's "Try again".
    public func retryMergeOffer() {
        guard let offer = mergeOffer, case .failed = offer.stage else { return }
        offerMerge(of: offer.caught, into: offer.existing)
    }

    /// "Merge": the merged card is written — the flashcard keeps its progress — and the phrase leaves Caught.
    /// Takes the offer as shown: the sheet closes (clearing `mergeOffer`) before its action runs.
    public func confirmMerge(_ shown: MergeOffer? = nil) {
        guard let offer = shown ?? mergeOffer, case .ready(let merge) = offer.stage, let duplicates, !isMerging else { return }
        mergeOffer = nil
        isMerging = true
        let members = (offer.existing + [offer.caught]).filter { merge.expressionIDs.contains($0.id) }
        let studied = studiedLanguage(), native = nativeLanguage()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await duplicates.merge(members, into: merge.card, as: merge.kind,
                                           studiedLanguage: studied, nativeLanguage: native)
                self.removeRow(offer.caught.id)
            } catch {
                self.report(Loc.t("Не удалось объединить.", "Couldn't merge.") + " " + presentableError(error).message,
                            for: error)
            }
            self.isMerging = false
        }
    }

    /// "Add as a separate card": the model writes the phrase's card afresh (`FixCardsUseCase.fix`, as a
    /// new card), it goes into flashcards, and it's linked to the look-alikes as "not duplicates" — the
    /// duplicate search won't offer them again, and the card shows the link.
    public func addSeparately(_ shown: MergeOffer? = nil) {
        guard let offer = shown ?? mergeOffer, let flashcards else { return }
        mergeOffer = nil
        let caught = offer.caught, existing = offer.existing.map(\.id)
        movingIDs.insert(caught.id)
        let studied = studiedLanguage(), native = nativeLanguage()
        Task { [weak self] in
            guard let self else { return }
            defer { self.movingIDs.remove(caught.id) }
            do {
                if let fixCards = self.fixCards {
                    self.replaceRow(with: try await fixCards.fix(caught, studiedLanguage: studied, nativeLanguage: native))
                }
                try await flashcards.enroll(caught.id, now: Date())
                try await self.duplicates?.keepApart(caught.id, from: existing)
                self.removeRow(caught.id)
            } catch {
                self.report(Self.moveFailure(error, moved: nil, of: 1), for: error)
            }
        }
    }

    /// Complete (if it lacks fields) and enrol one phrase; its row leaves only once it's moved.
    private func moveOne(_ expression: Domain.Expression) async {
        guard let flashcards else { return }
        movingIDs.insert(expression.id)
        defer { movingIDs.remove(expression.id) }
        do {
            let completed = try await completed([expression]).first ?? expression
            replaceRow(with: completed)
            try await flashcards.enroll(expression.id, now: Date())
            removeRow(expression.id)
        } catch {
            report(Self.moveFailure(error, moved: nil, of: 1), for: error)
        }
    }

    /// Show why a move or a merge stopped — with the subscription offered when it was the plan's limit.
    private func report(_ message: String, for error: Error) {
        actionError = message
        actionNeedsSubscription = presentableError(error).needsSubscription
    }

    /// The phrases with what they lacked filled in — as they are when Fix cards isn't wired.
    private func completed(_ batch: [Domain.Expression]) async throws -> [Domain.Expression] {
        guard let fixCards else { return batch }
        return try await fixCards.complete(batch, studiedLanguage: studiedLanguage(), nativeLanguage: nativeLanguage())
    }

    private func replaceRow(with expression: Domain.Expression) {
        if let index = expressions.firstIndex(where: { $0.id == expression.id }) { expressions[index] = expression }
    }

    private func removeRow(_ id: UUID) {
        expressions.removeAll { $0.id == id }
        lookAlikeIDs.remove(id)
        inFlashcardsIDs.remove(id)
        if expressions.isEmpty { phase = .empty }
    }

    /// Why the move stopped, and — for a bulk move — how far it got.
    static func moveFailure(_ error: Error, moved: Int?, of total: Int) -> String {
        let reason = presentableError(error).message
        guard let moved, total > 1 else {
            return Loc.t("Не удалось перенести во флеш-карты.", "Couldn't move to flashcards.") + " " + reason
        }
        return Loc.t("Перенос остановлен: перенесено \(moved) из \(total).", "The move stopped: \(moved) of \(total) moved.",
                     "Déplacement interrompu : \(moved) sur \(total) déplacées.", "Traslado detenido: \(moved) de \(total) movidas.",
                     "Verschieben gestoppt: \(moved) von \(total) verschoben.", "Spostamento interrotto: \(moved) di \(total) spostate.")
            + " " + reason
    }

    /// The phrases this one is marked "not duplicates" with (In flashcards).
    public func notDuplicates(of expression: Domain.Expression) -> [String] {
        let ids = Set(notDuplicateIDs[expression.id] ?? [])
        return expressions.filter { ids.contains($0.id) }.map(\.en)
    }

    /// An expression's cards, recognition first (empty on Caught).
    public func cards(for expression: Domain.Expression) -> [ReviewCard] {
        (cardsByExpression[expression.id] ?? []).sorted { $0.direction == .recognition && $1.direction != .recognition }
    }

    /// Whether Caught offers "move to flashcards" (flashcards wired).
    public var canMoveToFlashcards: Bool { flashcards != nil && scope == .caught }

    /// Caught: which rows are in flashcards already (the very same phrase), which look like a phrase
    /// there (`lookAlikesInFlashcards`, on the device), and — the rest — new. Off the main actor: keying
    /// thousands of phrases takes a moment, and the list is already shown meanwhile.
    private func markCaught(_ caught: [Domain.Expression]) async {
        guard let duplicates, !caught.isEmpty else {
            lookAlikeIDs = []
            inFlashcardsIDs = []
            marksKnown = true
            return
        }
        let language = studiedLanguage()
        let found = await Task.detached(priority: .userInitiated) {
            (try? await duplicates.lookAlikesInFlashcards(for: caught, studiedLanguage: language)) ?? [:]
        }.value
        lookAlikeIDs = Set(found.keys)
        inFlashcardsIDs = Set(caught.compactMap { phrase in
            let key = Domain.Expression.matchKey(phrase.en)
            return found[phrase.id]?.contains { Domain.Expression.matchKey($0.en) == key } == true ? phrase.id : nil
        })
        marksKnown = true
    }

    /// The Caught phrases "Move new" takes: the ones marked new (none until the marks are known).
    public var newPhrases: [Domain.Expression] {
        expressions.filter { mark($0) == .new }
    }

    /// "Move new": every NEW caught phrase goes into flashcards, no question asked; the ones that look
    /// like phrases already there stay — marked — to be merged one by one. Oldest first, in groups of
    /// `FixCardsInteractor.batchSize`: the phrases of a group that lack fields are completed by the model
    /// in one request, then each phrase gets its cards and leaves the list — one by one, so the list
    /// always shows exactly what hasn't moved. The first failure — offline, the plan's limit, no answer,
    /// a store error — stops the move and says how far it got; Stop does too.
    public func moveNewToFlashcards() {
        guard let flashcards, canMoveToFlashcards, bulkMove == nil, movingIDs.isEmpty, mergeOffer == nil else { return }
        let moving = newPhrases.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        guard !moving.isEmpty else { return }
        bulkMove = BulkMove(done: 0, total: moving.count)
        bulkMoveTask = Task { [weak self] in
            guard let self else { return }
            let now = Date()
            var done = 0
            defer {
                self.movingIDs = []
                self.bulkMove = nil
                self.bulkMoveTask = nil
            }
            do {
                for start in stride(from: 0, to: moving.count, by: FixCardsInteractor.batchSize) {
                    try Task.checkCancellation()
                    let group = Array(moving[start..<min(start + FixCardsInteractor.batchSize, moving.count)])
                    self.movingIDs = Set(group.map(\.id))
                    let completed = try await self.completed(group)
                    completed.forEach(self.replaceRow)
                    for expression in completed {
                        try Task.checkCancellation()
                        // A millisecond apart: the queue introduces new cards in the order they were moved in.
                        try await flashcards.enroll(expression.id, now: now.addingTimeInterval(Double(done) / 1_000))
                        self.removeRow(expression.id)
                        self.movingIDs.remove(expression.id)
                        done += 1
                        self.bulkMove = BulkMove(done: done, total: moving.count)
                    }
                }
            } catch is CancellationError {
                // Stop: what moved stays moved, the rest stays on the list.
            } catch LLMError.cancelled {
            } catch {
                self.report(Self.moveFailure(error, moved: done, of: moving.count), for: error)
            }
        }
    }

    /// Stop "Move all" after the phrase being moved; what moved stays moved.
    public func stopMoving() {
        bulkMoveTask?.cancel()
    }

    /// The whole list as cards — four lines each, separated by "---" (Copy all).
    public var allCardsText: String { Domain.Expression.cardsText(expressions) }

    // MARK: Fix one card

    /// The card view's wand: send the card to the model; the fixed texts replace its row (and the
    /// open card view shows them — it reads the row).
    public func fixCard(_ expression: Domain.Expression) {
        cardFix?.start(expression) { [weak self] fixed in self?.replaceRow(with: fixed) }
    }

    // MARK: Fix cards

    /// In flashcards offers "Fix cards".
    public var canFixCards: Bool { fixCards != nil && scope == .studying }

    /// Open the "Fix cards" sheet: it counts what each mode covers, then the user picks one.
    public func openFix() {
        guard let fixCards, fixSession == nil else { return }
        fixSession = FixCardsViewModel(fixCards: fixCards, studiedLanguage: studiedLanguage,
                                       nativeLanguage: nativeLanguage)
    }

    /// The sheet closed: the fixed texts appear.
    public func endFix() {
        fixSession?.stop()
        fixSession = nil
        Task { await load() }
    }

    // MARK: Find duplicates

    /// In flashcards offers "Find duplicates".
    public var canFindDuplicates: Bool { duplicates != nil && scope == .studying }

    public func openDuplicates() {
        guard let duplicates, duplicatesSession == nil else { return }
        duplicatesSession = DuplicatesViewModel(duplicates: duplicates, studiedLanguage: studiedLanguage,
                                                nativeLanguage: nativeLanguage)
    }

    /// The sheet closed (Done, or swiped away): what it was doing stops, and once the merge still under
    /// way has finished the list is read again — merged cards appear as one.
    public func endDuplicates() {
        guard let session = duplicatesSession else { return }
        session.stop()
        duplicatesSession = nil
        Task {
            await session.settle()
            await load()
        }
    }

    // MARK: Card files

    /// In flashcards offers export / import.
    public var canTransferCards: Bool { cardTransfer != nil && scope == .studying }

    /// The cards in flashcards with their progress → a .json card file, shared like the deck exports.
    public func exportCards() {
        guard let cardTransfer else { return }
        exportError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let now = Date()
                let data = try await cardTransfer.exportFlashcards(now: now).encoded()
                let day = now.formatted(.iso8601.year().month().day())
                self.exportedDeck = ExportedDeck(filename: "Gist It cards \(day).json", data: data,
                                                 contentType: "public.json")
            } catch {
                self.exportError = Loc.t("Не удалось создать файл для экспорта.", "Couldn't create the export file.")
            }
        }
    }

    /// A picked card file → straight into flashcards; the list reloads and an alert tells the outcome.
    public func importCards(_ data: Data) {
        guard let cardTransfer, !isImporting else { return }
        isImporting = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isImporting = false }
            do {
                let file = try CardFile.decode(data)
                let report = try await cardTransfer.importIntoFlashcards(file, now: Date())
                self.importMessage = Self.message(for: report)
                await self.load()
            } catch CardFileError.newerVersion {
                self.importMessage = Loc.t("Файл создан более новой версией приложения. Обновите приложение.",
                                           "This file was made by a newer version of the app. Update the app.")
            } catch CardFileError.notACardFile {
                self.importMessage = Loc.t("Это не файл карточек Gist It.", "This isn't a Gist It card file.")
            } catch {
                self.importMessage = Loc.t("Не удалось импортировать карточки. Попробуйте ещё раз.",
                                           "Couldn't import the cards. Try again.")
            }
        }
    }

    /// The picked file couldn't be read at all.
    public func reportImportReadFailed() {
        importMessage = Loc.t("Не удалось открыть файл.", "Couldn't open the file.")
    }

    public func clearImportMessage() { importMessage = nil }

    static func message(for report: CardImportReport) -> String {
        var parts = [Loc.t("Добавлено во флеш-карты: \(report.imported)", "Added to flashcards: \(report.imported)",
                           "Ajoutées aux cartes mémoire : \(report.imported)", "Añadidas a las tarjetas: \(report.imported)",
                           "Zu den Karteikarten hinzugefügt: \(report.imported)", "Aggiunte alle flashcard: \(report.imported)")]
        if report.movedFromCaught > 0 {
            parts.append(Loc.t("из них из «Пойманных»: \(report.movedFromCaught)", "of them from Caught: \(report.movedFromCaught)",
                               "dont depuis « Capturées » : \(report.movedFromCaught)", "de ellas desde «Atrapadas»: \(report.movedFromCaught)",
                               "davon aus „Eingefangen“: \(report.movedFromCaught)", "di cui da «Catturate»: \(report.movedFromCaught)"))
        }
        if report.alreadyInFlashcards > 0 {
            parts.append(Loc.t("уже были во флеш-картах: \(report.alreadyInFlashcards)", "already in flashcards: \(report.alreadyInFlashcards)",
                               "déjà dans les cartes mémoire : \(report.alreadyInFlashcards)", "ya estaban en las tarjetas: \(report.alreadyInFlashcards)",
                               "schon in den Karteikarten: \(report.alreadyInFlashcards)", "già nelle flashcard: \(report.alreadyInFlashcards)"))
        }
        if report.skipped > 0 {
            parts.append(Loc.t("пропущено (повторы и пустые): \(report.skipped)", "skipped (repeats and empty): \(report.skipped)",
                               "ignorées (doublons et vides) : \(report.skipped)", "omitidas (repetidas y vacías): \(report.skipped)",
                               "übersprungen (Wiederholungen und leere): \(report.skipped)", "saltate (ripetute e vuote): \(report.skipped)"))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: Catch from photos

    public var canCatchFromPhotos: Bool { catchFromPhotos != nil && scope == .caught }

    /// Open the progress sheet for `photoCount` picked photos; the view loads them and calls `run`.
    public func startCatch(photoCount: Int) -> CatchFromPhotosViewModel? {
        guard let catchFromPhotos, photoCount > 0, catchSession == nil else { return nil }
        let session = CatchFromPhotosViewModel(photoCount: photoCount, catchCards: catchFromPhotos)
        catchSession = session
        return session
    }

    /// The sheet closed: the caught cards appear.
    public func endCatch() {
        catchSession?.cancel()
        catchSession = nil
        Task { await load() }
    }

    public func export(_ format: ExportFormat) {
        exportError = nil
        let useCase = format == .anki ? exportAnki : exportAlgoApp
        Task { [weak self] in
            guard let self else { return }
            do {
                self.exportedDeck = try await useCase()
            } catch ExportError.nothingToExport {
                self.exportError = Loc.t("Список пуст — нечего экспортировать.", "The list is empty — nothing to export.")
            } catch {
                self.exportError = Loc.t("Не удалось создать файл для экспорта.", "Couldn't create the export file.")
            }
        }
    }

    /// The export file produced fine but writing it to a temp URL for sharing failed (L20): surface it
    /// instead of the share sheet silently never appearing.
    public func reportExportWriteFailed() {
        exportedDeck = nil
        exportError = Loc.t("Не удалось подготовить файл для отправки.",
                            "Couldn't prepare the file for sharing.")
    }

    // MARK: Playback

    public func isPlaying(_ expression: Domain.Expression) -> Bool { playingID == expression.id }

    public func play(_ expression: Domain.Expression) {
        if playingID == expression.id { stopPlayback(); return }   // tap again = stop
        playTask?.cancel()
        playingID = expression.id
        playTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await state in self.pronounce(expression.en) where state == .finished { break }
            } catch {
                // playback failure is non-fatal
            }
            if !Task.isCancelled, self.playingID == expression.id { self.playingID = nil }
        }
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
        playingID = nil
    }

    public func clearExport() { exportedDeck = nil }
    public func clearExportError() { exportError = nil }
    public func clearActionError() {
        actionError = nil
        actionNeedsSubscription = false
    }
}
