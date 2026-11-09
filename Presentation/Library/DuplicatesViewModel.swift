//
//  DuplicatesViewModel.swift
//  EnglishHelper — Presentation
//
//  In flashcards → "Find duplicates", one sheet: it reads the phrases (with progress) and groups the
//  look-alikes; "Check" sends the groups to the model — a two-part progress, sent (grey) and answered
//  (green) — and each group gets a verdict (duplicate / several meanings / different) with the card
//  it would make merged. The user merges a group, keeps it apart ("not duplicates" — it isn't
//  offered again), or merges every duplicate at once; groups can be decided while the rest are
//  still being checked.
//

import Foundation
import Domain

@MainActor
@Observable
public final class DuplicatesViewModel: Identifiable {
    public enum Phase: Equatable { case scanning, found, checking, checked, stopped, failed }

    public let id = UUID()
    public private(set) var phase: Phase = .scanning
    public private(set) var scan = DuplicateScanStep(checked: 0, total: 0)
    public private(set) var check = DuplicateCheckStep(sent: 0, answered: 0, total: 0)
    /// Groups still to decide on, oldest first.
    public private(set) var groups: [DuplicateGroup] = []
    /// The model's verdicts, by group id.
    public private(set) var verdicts: [String: DuplicateVerdict] = [:]
    /// Groups merged in this sheet.
    public private(set) var merged = 0
    /// Groups being merged right now.
    public private(set) var merging: Set<String> = []
    public private(set) var errorMessage: String?
    /// The plan's limit stopped the check: offer the subscription.
    public private(set) var needsSubscription = false

    private let duplicates: any DuplicatesUseCase
    private let studiedLanguage: () -> String
    private let nativeLanguage: () -> String
    private var task: Task<Void, Never>?

    public init(duplicates: any DuplicatesUseCase,
                studiedLanguage: @escaping () -> String = { StudiedLanguage.current.promptName },
                nativeLanguage: @escaping () -> String = { TargetLanguage.current.promptName }) {
        self.duplicates = duplicates
        self.studiedLanguage = studiedLanguage
        self.nativeLanguage = nativeLanguage
    }

    /// Groups the model called duplicates, still to decide on.
    public var duplicateGroups: [DuplicateGroup] { groups.filter { verdicts[$0.id]?.verdict == .duplicate } }
    /// Groups not sent to the model yet (a stopped check sends them next time).
    public var unchecked: [DuplicateGroup] { groups.filter { verdicts[$0.id] == nil } }
    public var isBusy: Bool { phase == .scanning || phase == .checking }

    /// Read the phrases and group the look-alikes.
    public func start() {
        guard task == nil, phase == .scanning else { return }
        let language = studiedLanguage()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await step in self.duplicates.scan(studiedLanguage: language) {
                    self.scan = step
                    if let groups = step.groups { self.groups = groups }
                }
                self.phase = self.groups.isEmpty ? .checked : .found
            } catch is CancellationError {
                self.phase = .stopped
            } catch {
                self.errorMessage = presentableError(error).message
                self.phase = .failed
            }
            self.task = nil
        }
    }

    /// Send the groups without a verdict to the model.
    public func startCheck() {
        let pending = unchecked
        guard task == nil, !pending.isEmpty else { return }
        phase = .checking
        errorMessage = nil
        needsSubscription = false
        let studied = studiedLanguage(), native = nativeLanguage()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await step in self.duplicates.check(pending, studiedLanguage: studied, nativeLanguage: native) {
                    self.check = step
                    self.verdicts.merge(step.verdicts) { _, new in new }
                }
                self.phase = .checked
            } catch is CancellationError {
                self.phase = .stopped
            } catch LLMError.cancelled {
                self.phase = .stopped
            } catch {
                let presentable = presentableError(error)
                self.errorMessage = presentable.message
                self.needsSubscription = presentable.needsSubscription
                self.phase = .failed
            }
            self.task = nil
        }
    }

    /// Stop reading, or stop checking after the current batch — the verdicts so far stay.
    public func stop() {
        task?.cancel()
    }

    /// Merge the group into the card the model proposed — as several meanings if it said they aren't
    /// one meaning twice (merging "different" ones is the user's call).
    public func merge(_ group: DuplicateGroup) {
        Task { await self.performMerge(group) }
    }

    /// Merge every group the model called duplicates, one after another.
    public func mergeAllDuplicates() {
        let all = duplicateGroups
        Task { for group in all { await self.performMerge(group) } }
    }

    private func performMerge(_ group: DuplicateGroup) async {
        guard let verdict = verdicts[group.id], !merging.contains(group.id) else { return }
        merging.insert(group.id)
        defer { merging.remove(group.id) }
        do {
            try await duplicates.merge(group.expressions, into: verdict.card,
                                       as: verdict.verdict == .duplicate ? .duplicate : .senses,
                                       studiedLanguage: studiedLanguage(), nativeLanguage: nativeLanguage())
            groups.removeAll { $0.id == group.id }
            merged += 1
        } catch {
            errorMessage = Loc.t("Не удалось объединить. Попробуйте ещё раз.", "Couldn't merge. Try again.")
        }
    }

    /// "Not duplicates": the group leaves the list and isn't offered again.
    public func keepApart(_ group: DuplicateGroup) {
        groups.removeAll { $0.id == group.id }
        Task { await duplicates.dismiss(group) }
    }
}
