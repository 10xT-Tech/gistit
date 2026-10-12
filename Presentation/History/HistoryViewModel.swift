//
//  HistoryViewModel.swift
//  EnglishHelper — Presentation
//
//  "История" — chronological log of every request (how-to-say / translate / photo / live session).
//  Rows can be swipe-deleted; a deleted live session takes its audio recording with it.
//

import Foundation
import Domain

@MainActor
@Observable
public final class HistoryViewModel {
    public enum Phase: Equatable { case loading, loaded, empty, failed }

    public private(set) var phase: Phase = .loading
    public private(set) var entries: [HistoryEntry] = []
    public private(set) var errorMessage: String?
    /// A row-action failure (delete) shown as an alert over whatever is on screen.
    public private(set) var actionError: String?

    private let history: any RequestHistoryUseCase
    private let saveExpression: any SaveExpressionUseCase
    private let studyList: any StudyListUseCase
    private let pronounce: any PlayPronunciationUseCase
    /// Session-recording playback for live-translation entries (nil in lean test setups).
    private let recordings: (any SessionRecordingsManaging)?
    private let limit = 200

    public init(
        history: any RequestHistoryUseCase,
        saveExpression: any SaveExpressionUseCase,
        studyList: any StudyListUseCase,
        pronounce: any PlayPronunciationUseCase,
        recordings: (any SessionRecordingsManaging)? = nil
    ) {
        self.history = history
        self.saveExpression = saveExpression
        self.studyList = studyList
        self.pronounce = pronounce
        self.recordings = recordings
    }

    /// VM for the read-only detail, which can also save phrases into the study list and play them.
    public func makeDetailViewModel(for entry: HistoryEntry) -> HistoryDetailViewModel {
        HistoryDetailViewModel(
            entry: entry, saveExpression: saveExpression, studyList: studyList,
            pronounce: pronounce, recordings: recordings
        )
    }

    public func load() async {
        // Spinner only before the first answer: a known-empty list reloading (e.g. uncovered under a
        // tab swipe) keeps its empty state instead of flashing "Loading…".
        if entries.isEmpty, phase != .empty { phase = .loading }
        do {
            let items = try await history.recent(limit: limit)   // most-recent-first
            entries = items
            phase = items.isEmpty ? .empty : .loaded
        } catch {
            errorMessage = Loc.t("Не удалось загрузить историю.", "Couldn't load history.")
            phase = .failed
        }
    }

    /// Swipe-delete: optimistic removal with revert on failure (same shape as the study list).
    public func delete(_ entry: HistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let removed = entries.remove(at: index)
        let priorPhase = phase
        if entries.isEmpty { phase = .empty }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.history.delete(entry)   // row + its audio recording, if any
            } catch {
                // Persisted delete failed → re-insert so the visible list can't diverge from the store.
                self.entries.insert(removed, at: min(index, self.entries.count))
                self.phase = priorPhase
                self.actionError = Loc.t("Не удалось удалить. Попробуйте ещё раз.",
                                         "Couldn't delete. Try again.")
            }
        }
    }

    public func clearActionError() { actionError = nil }
}
