//
//  StudyListViewModel.swift
//  EnglishHelper — Presentation
//
//  "Saved for later" — the expressions saved from Say it / Get it / See it (or added by hand) that
//  aren't in flashcards yet. Manual add (enrich-then-store), delete, move to flashcards, play, and
//  export of every saved expression to an AlgoApp .xml / Anki deck.
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
            let all = try await studyList.list()
            let enrolled = try await flashcards?.enrolledExpressionIDs() ?? []
            let items = all.filter { !enrolled.contains($0.id) }
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

    /// Whether rows offer "move to flashcards" (flashcards wired).
    public var canMoveToFlashcards: Bool { flashcards != nil }

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
