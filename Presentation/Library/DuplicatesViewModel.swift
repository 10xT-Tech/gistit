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
//  What may run at the same time — every write to a group is one at a time:
//  - "Merge all duplicates" is ONE run (`mergeAll`: progress, Stop): its groups are `busy` until their
//    merges are made, so their own buttons wait; a second tap, a full re-check and a new Check wait
//    for it; closing the sheet stops it after the merge under way (`settle`);
//  - a group the running Check has asked the model about (`awaiting`) keeps its Merge until the answer
//    comes — the answer is about the group AS SENT, and "Merge all" leaves such groups for later;
//  - an answer about a group that changed since it was sent is dropped (`adopt`): the group stays
//    unchecked as it is now.
//  The review found all three missing: two taps on "Merge all" made every merge twice ("Merged: 40" of
//  20), a merge during the Check left a proposal naming a deleted phrase (a Merge button that did
//  nothing), a full re-check made "Merge all" skip the rest silently, and closing the sheet left it
//  merging behind a list that had already been reloaded.
//

import Foundation
import Domain

@MainActor
@Observable
public final class DuplicatesViewModel: Identifiable {
    public enum Phase: Equatable { case scanning, found, checking, checked, stopped, failed }

    /// "Merge all duplicates" under way: merges gone through, of those it set out to make.
    public struct MergeAllStep: Equatable, Sendable {
        public let done: Int
        public let total: Int
        public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

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
    /// Groups being merged or checked on their own right now, and the groups "Merge all" is still to
    /// merge (by key) — their buttons wait.
    public private(set) var busy: Set<String> = []
    /// Groups the running Check has asked the model about and has no answer for yet (by key): their
    /// Merge waits for it.
    public private(set) var awaiting: Set<String> = []
    /// "Merge all duplicates" is running.
    public private(set) var mergeAll: MergeAllStep?
    public private(set) var errorMessage: String?
    /// The plan's limit stopped the check: offer the subscription.
    public private(set) var needsSubscription = false

    private let duplicates: any DuplicatesUseCase
    private let studiedLanguage: () -> String
    private let nativeLanguage: () -> String
    /// The scan or the Check.
    private var task: Task<Void, Never>?
    private var mergeAllTask: Task<Void, Never>?
    /// The groups' own merges under way, by key.
    private var groupMerges: [String: Task<Void, Never>] = [:]

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
    /// Every proposed duplicate merge "Merge all" would make now, with its group's key — none of a
    /// pair marked "not duplicates" before (a full re-check shows them; only the group's own Merge
    /// undoes the mark), and none in a group whose answer the Check still waits for.
    public var duplicateMerges: [(key: String, merge: DuplicateMerge)] {
        groups.filter { !awaiting.contains($0.key) }.flatMap { group in
            (proposals[group.key] ?? [])
                .filter { $0.kind == .duplicate && NotDuplicatePair.all(among: $0.expressionIDs).isDisjoint(with: group.marked) }
                .map { (key: group.key, merge: $0) }
        }
    }
    /// A run is under way — the scan, the Check or "Merge all": Stop is offered instead of Done.
    public var isBusy: Bool { phase == .scanning || phase == .checking || mergeAll != nil }

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
        // Not under a merge: it would clear the groups the merge is working through.
        guard task == nil, mergeAllTask == nil, groupMerges.isEmpty else { return }
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
        // Not under "Merge all": it changes the very groups the model would be asked about.
        guard task == nil, mergeAllTask == nil, !pending.isEmpty else { return }
        let asked = Self.members(of: pending)
        awaiting = Set(asked.keys)
        phase = .checking
        errorMessage = nil
        needsSubscription = false
        let studied = studiedLanguage(), native = nativeLanguage()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await step in self.duplicates.check(pending, studiedLanguage: studied, nativeLanguage: native) {
                    self.check = step
                    self.adopt(step.proposals, asked: asked)
                    self.awaiting.subtract(step.proposals.keys)
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
            self.awaiting = []
            self.task = nil
        }
    }

    /// Ask the model about one group only — unless the running Check is already asking about it.
    public func checkGroup(_ group: DuplicateGroup) {
        guard canDecide(group.key) else { return }
        busy.insert(group.key)
        let asked = Self.members(of: [group])
        let studied = studiedLanguage(), native = nativeLanguage()
        Task { [weak self] in
            guard let self else { return }
            defer { self.busy.remove(group.key) }
            do {
                for try await step in self.duplicates.check([group], studiedLanguage: studied, nativeLanguage: native) {
                    self.adopt(step.proposals, asked: asked)
                }
            } catch {
                self.fail(error)
            }
        }
    }

    /// Stop reading, stop checking after the current batches (the proposals so far stay), stop "Merge
    /// all" after the merge under way (a merge is never cut in the middle).
    public func stop() {
        task?.cancel()
        mergeAllTask?.cancel()
    }

    /// The merges still under way — a stopped "Merge all" finishing its current one, a group's own.
    /// The sheet's owner waits for it before reloading the list behind.
    public func settle() async {
        await mergeAllTask?.value
        for merge in Array(groupMerges.values) { await merge.value }
    }

    /// Whether the group's own buttons act now: nothing is writing it, and the Check isn't waiting for
    /// the model's answer about it.
    private func canDecide(_ key: String) -> Bool {
        !busy.contains(key) && !awaiting.contains(key)
    }

    /// Merge: make the group's proposals; what a checked group leaves out is marked "not duplicates".
    public func mergeGroup(_ group: DuplicateGroup) {
        let key = group.key
        guard canDecide(key), !(proposals[key] ?? []).isEmpty else { return }
        busy.insert(key)
        groupMerges[key] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy.remove(key)
                self.groupMerges[key] = nil
            }
            for merge in self.proposals[key] ?? [] {
                guard await self.perform(merge, in: key) else { break }
            }
        }
    }

    /// Make every proposed duplicate merge, one after another — one run at a time, with its progress;
    /// Stop ends it after the merge under way, and so does the first merge that fails (a store that
    /// can't write one won't write the next). Its groups are `busy` until their merges are made.
    public func mergeAllDuplicates() {
        let all = duplicateMerges
        guard mergeAllTask == nil, busy.isEmpty, phase != .scanning, !all.isEmpty else { return }
        let perGroup = Dictionary(grouping: all, by: \.key).mapValues(\.count)
        busy.formUnion(perGroup.keys)
        mergeAll = MergeAllStep(done: 0, total: all.count)
        mergeAllTask = Task { [weak self] in
            var left = perGroup                                  // merges still to make, by group
            for (index, item) in all.enumerated() {
                guard let self, !Task.isCancelled else { break }
                let made = await self.perform(item.merge, in: item.key)
                self.mergeAll = MergeAllStep(done: index + 1, total: all.count)
                left[item.key, default: 1] -= 1
                if left[item.key] == 0 {
                    left[item.key] = nil
                    self.busy.remove(item.key)
                }
                guard made else { break }
            }
            guard let self else { return }
            self.busy.subtract(left.keys)
            self.mergeAll = nil
            self.mergeAllTask = nil
        }
    }

    /// Don't merge: the group's phrases are marked "not duplicates" of each other and it leaves the list.
    public func keepApart(_ group: DuplicateGroup) {
        guard !busy.contains(group.key) else { return }       // it's being merged right now
        remove(group.key)
        let ids = group.expressions.map(\.id)
        Task { [weak self] in
            do { try await self?.duplicates.markNotDuplicates(ids) } catch { self?.fail(error) }
        }
    }

    private static func members(of groups: [DuplicateGroup]) -> [String: [UUID]] {
        Dictionary(groups.map { ($0.key, $0.expressions.map(\.id)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Takes the model's answers — for the groups that are still as they were SENT (`asked`: their
    /// phrases then). A group that was merged in, or left, since then keeps what it has: the answer is
    /// about phrases that are gone, and the group stays unchecked as it is now.
    private func adopt(_ found: [String: [DuplicateMerge]], asked: [String: [UUID]]) {
        for (key, merges) in found {
            guard let group = groups.first(where: { $0.key == key }),
                  group.expressions.map(\.id) == asked[key] else { continue }
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

    /// Makes one merge. False when it FAILED (the message says so); a merge with nothing left to do —
    /// its group gone, or fewer than two of its phrases still there — is dropped and isn't a failure.
    @discardableResult
    private func perform(_ merge: DuplicateMerge, in key: String) async -> Bool {
        guard let group = groups.first(where: { $0.key == key }) else { return true }
        let members = group.expressions.filter { merge.expressionIDs.contains($0.id) }
        guard members.count > 1 else {
            proposals[key]?.removeAll { $0.id == merge.id }     // never a Merge button that does nothing
            return true
        }
        do {
            try await duplicates.merge(members, into: merge.card, as: merge.kind,
                                       studiedLanguage: studiedLanguage(), nativeLanguage: nativeLanguage())
            merged += 1
            await resolve(merge, members: members, in: key)
            return true
        } catch {
            errorMessage = Loc.t("Не удалось объединить. Попробуйте ещё раз.", "Couldn't merge. Try again.")
            return false
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
