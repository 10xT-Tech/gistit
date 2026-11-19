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
//  - there is ONE LINE to the model for the sheet (`line`, `requests`): "Check" puts every unchecked
//    group on it, a group's own Check puts that group at its head — and the line sends them
//    `DuplicatesInteractor.batchSize` a request, at most `inFlight` requests at once, whoever asked.
//    A tapped group waits a moment (`gatherDelay`) so the next taps ride in the same request. One
//    progress, one Stop (it cancels the requests out), one rule for a failure (`RunFailure`: the
//    service not answering ends the run, a batch without an answer just stays unchecked);
//  - a group on the line or out with a request (`awaiting`) keeps its Merge until the answer comes —
//    the answer is about the group AS SENT, and "Merge all" leaves such groups for later; a group
//    being merged isn't put on the line;
//  - an answer about a group that changed since it was sent is dropped (`adopt`): the group stays
//    unchecked as it is now.
//  The review found all three missing: two taps on "Merge all" made every merge twice ("Merged: 40" of
//  20), a merge during the Check left a proposal naming a deleted phrase (a Merge button that did
//  nothing), a full re-check made "Merge all" skip the rest silently, and closing the sheet left it
//  merging behind a list that had already been reloaded. And each group's Check used to be a request
//  of its own, outside the Check's ceiling: twelve taps were twelve requests at once (three for the
//  same groups through "Check"), a group could be asked about twice (its button, then "Check"), and
//  neither Stop nor closing the sheet reached those requests.
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

    /// The Check's progress in this run of the line: groups sent, groups whose request is over, of the
    /// groups put to the model.
    public struct CheckStep: Equatable, Sendable {
        public fileprivate(set) var sent = 0
        public fileprivate(set) var answered = 0
        public fileprivate(set) var total = 0
        /// Groups the model's answer was unusable for (they stay unchecked).
        public fileprivate(set) var failed = 0
    }

    public let id = UUID()
    public private(set) var phase: Phase = .scanning
    /// A full re-check: the groups marked "not duplicates" are checked again.
    public private(set) var isFull = false
    /// Marked groups a full re-check confirmed: the model proposed no merge in them.
    public private(set) var confirmedApart = 0
    public private(set) var scan = DuplicateScanStep(checked: 0, total: 0)
    public private(set) var check = CheckStep()
    /// Groups still to decide on, oldest first.
    public private(set) var groups: [DuplicateGroup] = []
    /// Proposed merges by group key: the exact duplicates at first, the model's once it checked the group.
    public private(set) var proposals: [String: [DuplicateMerge]] = [:]
    /// Groups the model has checked (by key).
    public private(set) var checkedKeys: Set<String> = []
    /// Merges made in this sheet.
    public private(set) var merged = 0
    /// Groups being merged right now, and the groups "Merge all" is still to merge (by key) — their
    /// buttons wait.
    public private(set) var busy: Set<String> = []
    /// Groups put to the model with no answer yet — waiting on the line or out with a request (by
    /// key): their Merge and Check wait for it.
    public private(set) var awaiting: Set<String> = []
    /// "Merge all duplicates" is running.
    public private(set) var mergeAll: MergeAllStep?
    public private(set) var errorMessage: String?
    /// The plan's limit stopped the check: offer the subscription.
    public private(set) var needsSubscription = false

    private let duplicates: any DuplicatesUseCase
    private let studiedLanguage: () -> String
    private let nativeLanguage: () -> String
    private var scanTask: Task<Void, Never>?
    /// The line to the model: groups waiting to be sent, in order.
    private var line: [DuplicateGroup] = []
    /// How many at the head of the line were put there by their own Check, in the order tapped.
    private var tappedAhead = 0
    /// The Check's requests out now.
    private var requests: [UUID: Task<Void, Never>] = [:]
    /// The moment a tapped group waits for the next tap before it's sent.
    private var gathering: Task<Void, Never>?
    private let gatherDelay: Duration
    private var mergeAllTask: Task<Void, Never>?
    /// The groups' own merges under way, by key.
    private var groupMerges: [String: Task<Void, Never>] = [:]

    public init(duplicates: any DuplicatesUseCase,
                studiedLanguage: @escaping () -> String = { StudiedLanguage.current.promptName },
                nativeLanguage: @escaping () -> String = { TargetLanguage.current.promptName },
                gatherDelay: Duration = .seconds(1)) {
        self.duplicates = duplicates
        self.studiedLanguage = studiedLanguage
        self.nativeLanguage = nativeLanguage
        self.gatherDelay = gatherDelay
    }

    /// Groups the model is still to check — not the ones made only of exact duplicates.
    public var unchecked: [DuplicateGroup] {
        groups.filter { !checkedKeys.contains($0.key) && !$0.isExactOnly }
    }
    /// The unchecked groups nobody has put to the model yet — what "Check the rest" would add.
    public var notAsked: [DuplicateGroup] {
        unchecked.filter { !awaiting.contains($0.key) }
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
        guard scanTask == nil, phase == .scanning, groups.isEmpty else { return }
        runScan(full: false)
    }

    /// Search again from scratch, ignoring the "not duplicates" marks — after the matching changed, or
    /// to think again.
    public func rescanFully() {
        // Not under the Check or a merge: it would clear the groups they are working through.
        guard scanTask == nil, phase != .checking, mergeAllTask == nil, groupMerges.isEmpty else { return }
        isFull = true
        confirmedApart = 0
        groups = []
        proposals = [:]
        checkedKeys = []
        check = CheckStep()
        errorMessage = nil
        needsSubscription = false
        phase = .scanning
        runScan(full: true)
    }

    private func runScan(full: Bool) {
        let language = studiedLanguage()
        scanTask = Task { [weak self] in
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
            self.scanTask = nil
        }
    }

    // MARK: The line to the model

    /// Check: put every group the model hasn't checked on the line — behind the groups tapped one by
    /// one — and send at once.
    public func startCheck() {
        // Not under "Merge all": it changes the very groups the model would be asked about.
        guard scanTask == nil, mergeAllTask == nil else { return }
        put(unchecked, first: false)
        send()
    }

    /// A group's own Check: the group goes to the head of the SAME line — sent after a moment, so the
    /// groups tapped right after it ride in one request. Nothing if it's already put to the model.
    public func checkGroup(_ group: DuplicateGroup) {
        guard scanTask == nil, put([group], first: true), gathering == nil else { return }
        gathering = Task { [weak self, gatherDelay] in
            try? await Task.sleep(for: gatherDelay)
            guard let self, !Task.isCancelled else { return }
            self.send()
        }
    }

    /// Puts groups on the line — not one already there or being merged. The first one starts a run:
    /// its own progress, the last run's error gone. False when there was nothing to put.
    @discardableResult
    private func put(_ more: [DuplicateGroup], first: Bool) -> Bool {
        let new = more.filter { canDecide($0.key) }
        guard !new.isEmpty else { return false }
        if phase != .checking {
            check = CheckStep()
            errorMessage = nil
            needsSubscription = false
            phase = .checking
        }
        check.total += new.count
        awaiting.formUnion(new.map(\.key))
        if first {
            line.insert(contentsOf: new, at: tappedAhead)        // behind the ones tapped before it
            tappedAhead += new.count
        } else {
            line.append(contentsOf: new)
        }
        return true
    }

    /// Sends what waits on the line, a batch a request, while fewer than `inFlight` requests are out —
    /// the one place a Check's request starts. The run is over once nothing waits and nothing is out.
    private func send() {
        gathering?.cancel()
        gathering = nil
        let studied = studiedLanguage(), native = nativeLanguage()
        while requests.count < DuplicatesInteractor.inFlight, !line.isEmpty {
            let batch = Array(line.prefix(DuplicatesInteractor.batchSize))
            line.removeFirst(batch.count)
            tappedAhead = max(0, tappedAhead - batch.count)
            let id = UUID(), asked = Self.members(of: batch)
            check.sent += batch.count
            requests[id] = Task { [weak self, duplicates] in
                let result: Result<[String: [DuplicateMerge]], any Error>
                do {
                    result = .success(try await duplicates.check(batch, studiedLanguage: studied, nativeLanguage: native))
                } catch {
                    result = .failure(error)
                }
                guard let self, self.requests[id] != nil else { return }      // the run ended meanwhile
                self.requests[id] = nil
                self.received(result, about: asked)
            }
        }
        finishCheckIfDrained()
    }

    /// A request is over. An answer is taken and the line moves on (a group the answer leaves out
    /// stays unchecked, counted); a failure ends the run — `check` throws only when the service doesn't
    /// answer or asking again can't help now, and the rest of the line would meet the same.
    private func received(_ result: Result<[String: [DuplicateMerge]], any Error>, about asked: [String: [UUID]]) {
        switch result {
        case .success(let found):
            adopt(found, asked: asked)
            awaiting.subtract(asked.keys)
            check.answered += asked.count
            check.failed += asked.keys.filter { found[$0] == nil }.count
            send()
        case .failure(let error):
            endCheck()
            if error is CancellationError || (error as? LLMError) == .cancelled {
                phase = .stopped
            } else {
                fail(error)
                phase = .failed
            }
        }
    }

    /// The run is over before the line emptied: the requests out are cancelled, what waited is let go.
    private func endCheck() {
        gathering?.cancel()
        gathering = nil
        for request in requests.values { request.cancel() }
        requests = [:]
        line = []
        tappedAhead = 0
        awaiting = []
        check.sent = check.answered                // nothing is out any more
    }

    private func finishCheckIfDrained() {
        guard phase == .checking, requests.isEmpty, line.isEmpty else { return }
        gathering?.cancel()
        gathering = nil
        phase = .checked
    }

    /// Stop reading; stop the Check — its requests are cancelled, the proposals so far stay; stop
    /// "Merge all" after the merge under way (a merge is never cut in the middle).
    public func stop() {
        scanTask?.cancel()
        if phase == .checking {
            endCheck()
            phase = .stopped
        }
        mergeAllTask?.cancel()
    }

    /// The merges still under way — a stopped "Merge all" finishing its current one, a group's own.
    /// The sheet's owner waits for it before reloading the list behind.
    public func settle() async {
        await mergeAllTask?.value
        for merge in Array(groupMerges.values) { await merge.value }
    }

    /// Whether the group's own buttons act now: nothing is writing it, and it isn't put to the model
    /// with the answer still to come.
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
            // A merge is a write of several steps: in a task of its own, so that stopping the run around
            // it (Stop, the sheet closing) can't cut it in the middle — whatever the use case does on
            // cancellation.
            let studied = studiedLanguage(), native = nativeLanguage()
            try await Task { [duplicates] in
                try await duplicates.merge(members, into: merge.card, as: merge.kind,
                                           studiedLanguage: studied, nativeLanguage: native)
            }.value
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
        dropGone(gone, except: key)
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

    /// A phrase without a marker can sit in two groups (with the verbs and with the nouns): once a merge
    /// in one took it away, the other group lets it go too — with the proposals that named it.
    private func dropGone(_ gone: Set<UUID>, except key: String) {
        guard !gone.isEmpty else { return }
        for group in groups where group.key != key && group.expressions.contains(where: { gone.contains($0.id) }) {
            let rest = group.expressions.filter { !gone.contains($0.id) }
            guard rest.count > 1, let index = groups.firstIndex(where: { $0.key == group.key }) else {
                remove(group.key)
                continue
            }
            groups[index] = DuplicateGroup(key: group.key, expressions: rest,
                                           cards: group.cards.filter { !gone.contains($0.key) },
                                           exact: group.exact.filter { $0.expressionIDs.allSatisfy { !gone.contains($0) } },
                                           marked: group.marked.filter { !gone.contains($0.first) && !gone.contains($0.second) },
                                           honorsMarks: group.honorsMarks)
            proposals[group.key] = proposals[group.key]?.filter { $0.expressionIDs.allSatisfy { !gone.contains($0) } }
        }
    }

    /// The group is decided and leaves the list — and the line, if it still waited there (an answer
    /// on its way finds no group and is let go).
    private func remove(_ key: String) {
        groups.removeAll { $0.key == key }
        proposals[key] = nil
        awaiting.remove(key)
        if let waiting = line.firstIndex(where: { $0.key == key }) {
            line.remove(at: waiting)
            if waiting < tappedAhead { tappedAhead -= 1 }
            check.total -= 1
            finishCheckIfDrained()
        }
    }
}
