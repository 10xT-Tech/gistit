//
//  StudyListViewModel.swift
//  EnglishHelper — Presentation
//
//  "Изучаю" — the study list. Manual add (enrich-then-store), swipe-delete, toggle learned,
//  export to an AlgoApp .xml / Anki deck, and the entry to flashcard practice (today's counts +
//  the running session).
//

import Foundation
import Domain

@MainActor
@Observable
public final class StudyListViewModel {
    public enum Phase: Equatable { case loading, loaded, empty, failed }

    public private(set) var phase: Phase = .loading
    public private(set) var expressions: [Domain.Expression] = []   // Domain.* avoids Foundation.Expression
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

    /// A failed delete / toggle-learned, surfaced without flipping the whole list to `.failed`.
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

    /// Today's flashcard counts; nil while unknown or with flashcards off (no use case wired).
    public private(set) var practice: FlashcardsSummary?
    /// The practice session on screen (presented full screen while non-nil).
    public var session: FlashcardSessionViewModel?

    private let studyList: any StudyListUseCase
    private let saveExpression: any SaveExpressionUseCase
    private let exportAlgoApp: any ExportDeckUseCase
    private let exportAnki: any ExportDeckUseCase
    private let pronounce: any PlayPronunciationUseCase
    private let isConfigured: Bool
    private let flashcards: (any FlashcardsUseCase)?
    private var playTask: Task<Void, Never>?

    public init(
        studyList: any StudyListUseCase,
        saveExpression: any SaveExpressionUseCase,
        exportAlgoApp: any ExportDeckUseCase,
        exportAnki: any ExportDeckUseCase,
        pronounce: any PlayPronunciationUseCase,
        isConfigured: Bool,
        flashcards: (any FlashcardsUseCase)? = nil
    ) {
        self.studyList = studyList
        self.saveExpression = saveExpression
        self.exportAlgoApp = exportAlgoApp
        self.exportAnki = exportAnki
        self.pronounce = pronounce
        self.isConfigured = isConfigured
        self.flashcards = flashcards
    }

    public var canAdd: Bool { !newEnglish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var needsAPIKey: Bool { !isConfigured }

    public func load() async {
        // Spinner only before the first answer: a known-empty list reloading (e.g. uncovered under a
        // tab swipe) keeps its empty state instead of flashing "Loading…".
        if expressions.isEmpty, phase != .empty { phase = .loading }
        do {
            let items = try await studyList.list()
            expressions = items
            phase = items.isEmpty ? .empty : .loaded
            await refreshPractice()
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
                await self.refreshPractice()
            } catch {
                // Persisted delete failed → re-insert so the visible list can't diverge from the store.
                self.expressions.insert(removed, at: min(index, self.expressions.count))
                self.phase = wasLoaded
                self.actionError = Loc.t("Не удалось удалить. Попробуйте ещё раз.",
                                         "Couldn't delete. Try again.")
            }
        }
    }

    /// Cards marked learned — what Clean up removes; 0 disables the button.
    public var learnedCount: Int { expressions.filter(\.learned).count }
    /// Clean up is a bulk delete with no undo, so the view asks for confirmation first.
    public var showCleanUpConfirmation = false

    /// Remove EVERY card marked learned. Optimistic like `delete`: the rows vanish at once; if any
    /// persisted delete fails the list is reloaded from the store so what's shown never diverges
    /// from it, and the failure is reported.
    public func cleanUpLearned() {
        let learned = expressions.filter(\.learned)
        guard !learned.isEmpty else { return }
        expressions.removeAll(where: \.learned)
        if expressions.isEmpty { phase = .empty }
        Task { [weak self] in
            guard let self else { return }
            var failed = false
            for expression in learned {
                do { try await self.studyList.delete(id: expression.id) } catch { failed = true }
            }
            if failed {
                await self.load()
                self.actionError = Loc.t("Не удалось удалить часть карточек. Попробуйте ещё раз.",
                                         "Couldn't delete some cards. Try again.")
            } else {
                await self.refreshPractice()
            }
        }
    }

    public func toggleLearned(_ expression: Domain.Expression) {
        let newValue = !expression.learned
        if let index = expressions.firstIndex(where: { $0.id == expression.id }) {
            expressions[index].learned = newValue
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.studyList.setLearned(newValue, id: expression.id)
                await self.refreshPractice()   // learned expressions leave practice
            } catch {
                // Revert the optimistic flip so the toggle reflects what's actually persisted.
                if let index = self.expressions.firstIndex(where: { $0.id == expression.id }) {
                    self.expressions[index].learned = !newValue
                }
                self.actionError = Loc.t("Не удалось обновить. Попробуйте ещё раз.",
                                         "Couldn't update. Try again.")
            }
        }
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

    // MARK: Flashcards

    /// Re-count today's cards (after loading, list edits, or a finished session).
    public func refreshPractice() async {
        guard let flashcards else { return }
        practice = try? await flashcards.summary(now: Date())
    }

    /// Open a practice session. The paywall check for the free plan is the view's (it owns the plan).
    public func startPractice() {
        guard let flashcards, session == nil else { return }
        session = FlashcardSessionViewModel(flashcards: flashcards, pronounce: pronounce)
    }

    /// The session screen closed.
    public func endPractice() {
        session = nil
        Task { await refreshPractice() }
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
