//
//  StudyListViewModel.swift
//  EnglishHelper — Presentation
//
//  The saved expressions, in one of two scopes:
//  - Caught: saved from Say it / Get it / See it or caught here (generated from a phrase, or from
//    photos) and not in flashcards yet — delete, move one or all into flashcards, copy as cards,
//    export every saved expression to an AlgoApp .xml / Anki deck.
//  - In flashcards: the expressions being learned — delete (with their cards); export them to a card
//    file with their progress, import a card file straight into flashcards.
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

    /// "Move all to flashcards" asks first.
    public var showMoveAllConfirmation = false
    /// Caught → From photos, on screen while non-nil.
    public var catchSession: CatchFromPhotosViewModel?
    /// "Fix cards": what a run of each scope would go through, asked before starting.
    public private(set) var fixRemaining: (left: Int, total: Int)?
    public private(set) var fixIncomplete: (left: Int, total: Int)?
    public var showFixConfirmation = false
    /// The "Fix cards" run on screen while non-nil.
    public var fixSession: FixCardsViewModel?
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
    private var playTask: Task<Void, Never>?

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
        scope: Scope = .caught
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
        self.scope = scope
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
            expressions = items
            phase = items.isEmpty ? .empty : .loaded
        } catch {
            errorMessage = Loc.t("Не удалось загрузить список.", "Couldn't load the list.")
            phase = .failed
        }
    }

    public func add() {
        let english = newEnglish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !english.isEmpty, !isAdding else { return }
        let context = newContext.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Move an expression into flashcards (its two cards are created; it leaves this list). Optimistic
    /// like `delete`: the row goes at once and comes back if the move fails.
    public func moveToFlashcards(_ expression: Domain.Expression) {
        guard let flashcards, let index = expressions.firstIndex(where: { $0.id == expression.id }) else { return }
        let moved = expressions.remove(at: index)
        let wasLoaded = phase
        if expressions.isEmpty { phase = .empty }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await flashcards.enroll(moved.id, now: Date())
            } catch {
                self.expressions.insert(moved, at: min(index, self.expressions.count))
                self.phase = wasLoaded
                self.actionError = Loc.t("Не удалось перенести во флеш-карты. Попробуйте ещё раз.",
                                         "Couldn't move to flashcards. Try again.")
            }
        }
    }

    /// An expression's cards, recognition first (empty on Caught).
    public func cards(for expression: Domain.Expression) -> [ReviewCard] {
        (cardsByExpression[expression.id] ?? []).sorted { $0.direction == .recognition && $1.direction != .recognition }
    }

    /// Whether Caught offers "move to flashcards" (flashcards wired).
    public var canMoveToFlashcards: Bool { flashcards != nil && scope == .caught }

    /// Move every caught expression into flashcards — the list empties. New cards are introduced in
    /// list order, oldest first.
    public func moveAllToFlashcards() {
        guard let flashcards, canMoveToFlashcards, !expressions.isEmpty else { return }
        let moving = expressions.sorted { $0.createdAt < $1.createdAt }
        expressions = []
        phase = .empty
        Task { [weak self] in
            guard let self else { return }
            let now = Date()
            var failed = false
            for (index, expression) in moving.enumerated() {
                // A millisecond apart: the queue introduces new cards in the order they were moved in.
                do { try await flashcards.enroll(expression.id, now: now.addingTimeInterval(Double(index) / 1_000)) }
                catch { failed = true }
            }
            if failed {
                await self.load()
                self.actionError = Loc.t("Не удалось перенести часть фраз. Попробуйте ещё раз.",
                                         "Couldn't move some phrases. Try again.")
            }
        }
    }

    /// The whole list as cards — four lines each, separated by "---" (Copy all).
    public var allCardsText: String { Domain.Expression.cardsText(expressions) }

    // MARK: Fix cards

    /// In flashcards offers "Fix cards".
    public var canFixCards: Bool { fixCards != nil && scope == .studying }

    /// Count what a run of each scope would cover, then ask (all: start / continue / start over;
    /// only the incomplete ones).
    public func prepareFix() {
        guard let fixCards else { return }
        Task { [weak self] in
            guard let self else { return }
            if let remaining = try? await fixCards.remaining(.all),
               let incomplete = try? await fixCards.remaining(.incomplete) {
                self.fixRemaining = remaining
                self.fixIncomplete = incomplete
                self.showFixConfirmation = remaining.total > 0
            }
        }
    }

    /// Run over the scope's phrases — `restart`: all of them again, not from where its last run stopped.
    public func startFix(_ scope: FixScope, restart: Bool) {
        guard let fixCards, fixSession == nil else { return }
        let session = FixCardsViewModel(fixCards: fixCards)
        fixSession = session
        session.run(scope, restart: restart)
    }

    /// The sheet closed: the fixed texts appear.
    public func endFix() {
        fixSession?.stop()
        fixSession = nil
        Task { await load() }
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
    public func clearActionError() { actionError = nil }
}
