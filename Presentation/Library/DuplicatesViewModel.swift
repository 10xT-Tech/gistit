//
//  DuplicatesViewModel.swift
//  EnglishHelper — Presentation
//
//  In flashcards → "Find duplicates", one sheet: it reads the phrases (with progress) and groups the
//  look-alikes. Exact duplicates (the same phrase and translation) are proposed at once; "Check" sends
//  the other groups to the model — a two-part progress, sent (grey) and answered (green) — and each
//  gets the merges it needs: which of its phrases are one card (a duplicate, or one expression's
//  several meanings) and the card they'd make; a phrase in no merge stays apart. Per group: Merge
//  (makes its proposals; the rest of a checked group is marked "not duplicates") or Don't merge (its
//  phrases are marked "not duplicates" of each other — with the cards — and a search leaves them be).
//  "Full re-check" searches again and puts the groups marked "not duplicates" to the model too — one
//  shows up only if a merge is proposed in it (`shownGroups`); the rest stay marked
//  (`confirmedApart`). Groups can be decided while the rest are still being checked.
//

import Foundation
import Domain

@MainActor
@Observable
public final class DuplicatesViewModel: Identifiable {
    public enum Phase: Equatable { case scanning, found, checking, checked, stopped, failed }

    public let id = UUID()
    public private(set) var phase: Phase = .scanning
    /// A full re-check: the groups marked "not duplicates" are checked again.
    public private(set) var isFull = false
    /// Marked groups a full re-check confirmed: the model proposed no merge in them.
    public private(set) var confirmedApart = 0
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
    /// Groups being merged or checked on their own right now (by key).
    public private(set) var busy: Set<String> = []
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
    /// The groups on screen: a group marked "not duplicates" (a full re-check) only once a merge is
    /// proposed in it — until then it's the model's question, not the user's.
    public var shownGroups: [DuplicateGroup] {
        groups.filter { !$0.isAllMarked || !(proposals[$0.key] ?? []).isEmpty }
    }
    /// Marked groups a full re-check still has to put to the model.
    public var markedToCheck: Int {
        groups.filter { $0.isAllMarked && (proposals[$0.key] ?? []).isEmpty }.count
    }
    /// Every proposed duplicate merge, with its group's key — but none of a pair marked "not
    /// duplicates" before (a full re-check shows them; only the group's own Merge undoes the mark).
    public var duplicateMerges: [(key: String, merge: DuplicateMerge)] {
        groups.flatMap { group in
            (proposals[group.key] ?? [])
                .filter { $0.kind == .duplicate && NotDuplicatePair.all(among: $0.expressionIDs).isDisjoint(with: group.marked) }
                .map { (key: group.key, merge: $0) }
        }
    }
    public var isBusy: Bool { phase == .scanning || phase == .checking }

    /// Whether a group's phrase outside every proposal is known to stay apart (the model said so, or
    /// the group is only exact duplicates).
    public func isSettled(_ group: DuplicateGroup) -> Bool {
        checkedKeys.contains(group.key) || group.isExactOnly
    }

    /// Read the phrases and group the look-alikes — leaving out what's marked "not duplicates".
    public func start() {
        guard task == nil, phase == .scanning, groups.isEmpty else { return }
        runScan(full: false)
    }

    /// Search again from scratch, ignoring the "not duplicates" marks — after the matching changed, or
    /// to think again.
    public func rescanFully() {
        guard task == nil else { return }
        isFull = true
        confirmedApart = 0
        groups = []
        proposals = [:]
        checkedKeys = []
        check = DuplicateCheckStep(sent: 0, answered: 0, total: 0)
        errorMessage = nil
        needsSubscription = false
        phase = .scanning
        runScan(full: true)
    }

    private func runScan(full: Bool) {
        let language = studiedLanguage()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await step in self.duplicates.scan(studiedLanguage: language, full: full) {
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
                    self.adopt(step.proposals)
                }
                self.phase = .checked
            } catch is CancellationError {
                self.phase = .stopped
            } catch LLMError.cancelled {
                self.phase = .stopped
            } catch {
                self.fail(error)
                self.phase = .failed
            }
            self.task = nil
        }
    }

    /// Ask the model about one group only.
    public func checkGroup(_ group: DuplicateGroup) {
        guard !busy.contains(group.key) else { return }
        busy.insert(group.key)
        let studied = studiedLanguage(), native = nativeLanguage()
        Task { [weak self] in
            guard let self else { return }
            defer { self.busy.remove(group.key) }
            do {
                for try await step in self.duplicates.check([group], studiedLanguage: studied, nativeLanguage: native) {
                    self.adopt(step.proposals)
                }
            } catch {
                self.fail(error)
            }
        }
    }

    /// Stop reading, or stop checking after the current batches — the proposals so far stay.
    public func stop() {
        task?.cancel()
    }

    /// Merge: make the group's proposals; what a checked group leaves out is marked "not duplicates".
    public func mergeGroup(_ group: DuplicateGroup) {
        let key = group.key
        guard !busy.contains(key), !(proposals[key] ?? []).isEmpty else { return }
        busy.insert(key)
        Task { [weak self] in
            guard let self else { return }
            defer { self.busy.remove(key) }
            for merge in self.proposals[key] ?? [] { await self.perform(merge, in: key) }
        }
    }

    /// Make every proposed duplicate merge, one after another.
    public func mergeAllDuplicates() {
        let all = duplicateMerges
        Task { for item in all { await self.perform(item.merge, in: item.key) } }
    }

    /// Don't merge: the group's phrases are marked "not duplicates" of each other and it leaves the list.
    public func keepApart(_ group: DuplicateGroup) {
        remove(group.key)
        let ids = group.expressions.map(\.id)
        Task { [weak self] in
            do { try await self?.duplicates.markNotDuplicates(ids) } catch { self?.fail(error) }
        }
    }

    private func adopt(_ found: [String: [DuplicateMerge]]) {
        for (key, merges) in found {
            guard let group = groups.first(where: { $0.key == key }) else { continue }
            if group.isAllMarked && merges.isEmpty {
                remove(key)                                    // the model agrees: they stay marked
                confirmedApart += 1
                continue
            }
            proposals[key] = merges
            checkedKeys.insert(key)
        }
    }

    private func fail(_ error: Error) {
        let presentable = presentableError(error)
        errorMessage = presentable.message
        needsSubscription = presentable.needsSubscription
    }

    private func perform(_ merge: DuplicateMerge, in key: String) async {
        guard let group = groups.first(where: { $0.key == key }) else { return }
        let members = group.expressions.filter { merge.expressionIDs.contains($0.id) }
        guard members.count > 1 else { return }
        do {
            try await duplicates.merge(members, into: merge.card, as: merge.kind,
                                       studiedLanguage: studiedLanguage(), nativeLanguage: nativeLanguage())
            merged += 1
            await resolve(merge, members: members, in: key)
        } catch {
            errorMessage = Loc.t("Не удалось объединить. Попробуйте ещё раз.", "Couldn't merge. Try again.")
        }
    }

    /// After a merge: the merged-away phrases leave the group, the kept one shows the merged card. A
    /// group of one is done; a settled group with nothing more proposed is done too — what's left of it
    /// is marked "not duplicates".
    private func resolve(_ merge: DuplicateMerge, members: [Domain.Expression], in key: String) async {
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
            do { try await duplicates.markNotDuplicates(remaining.map(\.id)) } catch { fail(error) }
        } else {
            groups[index] = DuplicateGroup(key: key, expressions: remaining,
                                           cards: group.cards.filter { !gone.contains($0.key) },
                                           exact: group.exact.filter { $0.id != merge.id },
                                           marked: group.marked.filter { !gone.contains($0.first) && !gone.contains($0.second) },
                                           honorsMarks: group.honorsMarks)
            proposals[key] = left
        }
    }

    private func remove(_ key: String) {
        groups.removeAll { $0.key == key }
        proposals[key] = nil
    }
}
