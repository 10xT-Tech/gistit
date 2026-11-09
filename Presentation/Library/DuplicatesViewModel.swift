//
//  DuplicatesViewModel.swift
//  EnglishHelper — Presentation
//
//  In flashcards → "Find duplicates", one sheet: it reads the phrases (with progress) and groups the
//  look-alikes. Exact duplicates (the same phrase and translation) can be merged at once; "Check"
//  sends the other groups to the model — a two-part progress, sent (grey) and answered (green) — and
//  each gets the merges it needs: which of its phrases are one card (a duplicate, or one expression's
//  several meanings) and the card they'd make; a phrase in no merge stays apart. The user merges a
//  proposal, keeps a group apart ("not duplicates" — not offered again), or merges every duplicate at
//  once; groups can be decided while the rest are still being checked. Once a checked group has no
//  proposal left, what's left of it is apart for good.
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
    /// Proposed merges by group key: the exact duplicates at first, the model's once it checked the group.
    public private(set) var proposals: [String: [DuplicateMerge]] = [:]
    /// Groups the model has checked (by key).
    public private(set) var checkedKeys: Set<String> = []
    /// Merges made in this sheet.
    public private(set) var merged = 0
    /// Merges being made right now (by merge id).
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

    /// Groups the model is still to check — not the ones made only of exact duplicates.
    public var unchecked: [DuplicateGroup] {
        groups.filter { !checkedKeys.contains($0.key) && !$0.isExactOnly }
    }
    /// Every proposed duplicate merge, with its group's key.
    public var duplicateMerges: [(key: String, merge: DuplicateMerge)] {
        groups.flatMap { group in
            (proposals[group.key] ?? []).filter { $0.kind == .duplicate }.map { (key: group.key, merge: $0) }
        }
    }
    public var isBusy: Bool { phase == .scanning || phase == .checking }

    /// Whether a group's phrase outside every proposal is known to stay apart (the model said so, or
    /// the group is only exact duplicates).
    public func isSettled(_ group: DuplicateGroup) -> Bool {
        checkedKeys.contains(group.key) || group.isExactOnly
    }

    /// Read the phrases and group the look-alikes.
    public func start() {
        guard task == nil, phase == .scanning else { return }
        let language = studiedLanguage()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await step in self.duplicates.scan(studiedLanguage: language) {
                    self.scan = step
                    if let groups = step.groups {
                        self.groups = groups
                        self.proposals = Dictionary(uniqueKeysWithValues: groups.map { ($0.key, $0.exact) })
                    }
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

    /// Send the groups the model hasn't checked to it.
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
                    for (key, merges) in step.proposals where self.groups.contains(where: { $0.key == key }) {
                        self.proposals[key] = merges
                        self.checkedKeys.insert(key)
                    }
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

    /// Stop reading, or stop checking after the current batch — the proposals so far stay.
    public func stop() {
        task?.cancel()
    }

    /// Make one proposed merge.
    public func merge(_ merge: DuplicateMerge, in group: DuplicateGroup) {
        let key = group.key
        Task { await self.perform(merge, in: key) }
    }

    /// Make every proposed duplicate merge, one after another.
    public func mergeAllDuplicates() {
        let all = duplicateMerges
        Task { for item in all { await self.perform(item.merge, in: item.key) } }
    }

    /// "Not duplicates": the group leaves the list and isn't offered again.
    public func keepApart(_ group: DuplicateGroup) {
        remove(group.key)
        let ids = group.expressions.map(\.id)
        Task { await duplicates.dismiss(ids) }
    }

    private func perform(_ merge: DuplicateMerge, in key: String) async {
        guard let group = groups.first(where: { $0.key == key }), !merging.contains(merge.id) else { return }
        let members = group.expressions.filter { merge.expressionIDs.contains($0.id) }
        guard members.count > 1 else { return }
        merging.insert(merge.id)
        defer { merging.remove(merge.id) }
        do {
            try await duplicates.merge(members, into: merge.card, as: merge.kind,
                                       studiedLanguage: studiedLanguage(), nativeLanguage: nativeLanguage())
            merged += 1
            resolve(merge, members: members, in: key)
        } catch {
            errorMessage = Loc.t("Не удалось объединить. Попробуйте ещё раз.", "Couldn't merge. Try again.")
        }
    }

    /// After a merge: the merged-away phrases leave the group, the kept one shows the merged card. A
    /// group of one is done; a settled group with nothing more proposed is apart for good.
    private func resolve(_ merge: DuplicateMerge, members: [Domain.Expression], in key: String) {
        guard let index = groups.firstIndex(where: { $0.key == key }),
              let kept = DuplicatesInteractor.kept(of: members, enrolled: Set(groups[index].cards.keys)) else { return }
        let group = groups[index]
        let gone = Set(merge.expressionIDs).subtracting([kept.id])
        let remaining = group.expressions.filter { !gone.contains($0.id) }.map { expression -> Domain.Expression in
            guard expression.id == kept.id else { return expression }
            var shown = expression
            shown.en = merge.card.expression
            shown.ru = merge.card.translation
            return shown
        }
        let left = (proposals[key] ?? []).filter { $0.id != merge.id }
        if remaining.count < 2 {
            remove(key)
        } else if left.isEmpty && isSettled(group) {
            remove(key)
            let ids = remaining.map(\.id)
            Task { await duplicates.dismiss(ids) }
        } else {
            groups[index] = DuplicateGroup(key: key, expressions: remaining,
                                           cards: group.cards.filter { !gone.contains($0.key) },
                                           exact: group.exact.filter { $0.id != merge.id })
            proposals[key] = left
        }
    }

    private func remove(_ key: String) {
        groups.removeAll { $0.key == key }
        proposals[key] = nil
    }
}
