//
//  DuplicatesView.swift
//  EnglishHelper — Presentation
//
//  The "Find duplicates" sheet: reading the phrases (a progress line), how many look-alike groups
//  there are and "Check" (the model), then the check's two-part line — sent in grey, answered in
//  green catching up — over the groups: each with its phrases and their progress, the proposed
//  merges (exact duplicates at once, the model's after the check) with the card each makes, and two
//  buttons — Merge / Don't merge ("not duplicates", kept with the cards); a group nobody checked yet
//  offers Check instead of Merge — it joins the sheet's one line to the model, with the same progress
//  and Stop as "Check" — and a group put to the model waits for the answer ("The model is checking…",
//  Merge off). "Merge all duplicates" takes the clear cases at once
//  — a run with its own progress line in place of the button, Stop in the toolbar, its groups
//  spinning until merged; "Full
//  re-check" searches again and has the model check the groups marked "not duplicates" too — they
//  show up only where it proposes a merge. The paywall is presented from here (a second sheet can't
//  open from the root).
//

import SwiftUI
import UIKit
import Domain
import DesignSystem

struct DuplicatesView: View {
    @State var model: DuplicatesViewModel
    let onClose: () -> Void
    @State private var showPaywall = false
    @State private var showSettled = false
    @Environment(SubscriptionState.self) private var subscription

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Tokens.Space.s16) {
                    status
                    if model.needsSubscription {
                        EHButton(Loc.t("Оформить подписку", "Subscribe"), kind: .primary, fillWidth: true) {
                            showPaywall = true
                        }
                    }
                    if let run = model.mergeAll {
                        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
                            ProgressLine(done: run.fraction)
                            Text(Loc.t("Сливаю дубли: \(run.done) из \(run.total)", "Merging duplicates: \(run.done) of \(run.total)",
                                       "Fusion des doublons : \(run.done) sur \(run.total)",
                                       "Uniendo duplicados: \(run.done) de \(run.total)",
                                       "Duplikate werden zusammengeführt: \(run.done) von \(run.total)",
                                       "Unione dei duplicati: \(run.done) di \(run.total)"))
                                .textStyle(Tokens.Text.subhead)
                                .foregroundStyle(Tokens.Content.secondary)
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Tokens.Space.s16)
                        .glassPanel(cornerRadius: Tokens.Radius.card)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("dups.mergingAll")
                    } else if !model.duplicateMerges.isEmpty {
                        let count = model.duplicateMerges.count
                        EHButton(Loc.t("Слить все дубли (\(count))", "Merge all duplicates (\(count))",
                                       "Fusionner tous les doublons (\(count))", "Unir todos los duplicados (\(count))",
                                       "Alle Duplikate zusammenführen (\(count))", "Unisci tutti i duplicati (\(count))"),
                                 icon: "arrow.triangle.merge", kind: .tonal, fillWidth: true,
                                 accessibilityID: "dups.mergeAll") { model.mergeAllDuplicates() }
                            .disabled(!model.busy.isEmpty)
                    }
                    ForEach(model.shownGroups) { group in
                        GroupCard(group: group, proposals: model.proposals[group.key] ?? [],
                                  isChecked: model.checkedKeys.contains(group.key), isSettled: model.isSettled(group),
                                  isBusy: model.busy.contains(group.key), isAwaited: model.awaiting.contains(group.key),
                                  onMerge: { model.mergeGroup(group) }, onCheck: { check { model.checkGroup(group) } },
                                  onKeepApart: { model.keepApart(group) })
                    }
                }
                .padding(.horizontal, Tokens.Space.s16)
                .padding(.bottom, Tokens.Space.s24)
            }
            .background(Tokens.Surface.background)
            .navigationTitle(Loc.t("Поиск дублей", "Find duplicates"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if model.isBusy {
                        Button(Loc.t("Стоп", "Stop")) { model.stop() }
                            .accessibilityIdentifier("dups.stop")
                    } else {
                        Button(Loc.t("Готово", "Done")) { onClose() }
                            .accessibilityIdentifier("dups.done")
                    }
                }
            }
            .sheet(isPresented: $showPaywall) { PaywallView().environment(subscription) }
            .navigationDestination(isPresented: $showSettled) {
                SettledGroupsView(model: model) { group in
                    // Merging a marked group with no exact duplicate in it asks the model: Pro.
                    if model.needsModel(toMerge: group) && !subscription.tier.canCheckDuplicates {
                        showPaywall = true
                    } else {
                        model.mergeSettled(group)
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.phase == .checking || model.mergeAll != nil)
        .task { model.start() }
        // Checking hundreds of groups takes a while: keep the screen on while it works.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Status

    private var status: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            Text(title)
                .textStyle(Tokens.Text.headline)
                .foregroundStyle(Tokens.Content.primary)
            if model.isFull {
                if model.markedToCheck > 0 {
                    caption(Loc.t("Полная перепроверка: группы, отмеченные «не дубли» (\(model.markedToCheck)), модель проверит заново и покажет только те, где теперь видит дубли.",
                                  "Full re-check: the model checks the groups marked \"not duplicates\" (\(model.markedToCheck)) again and shows only those it now finds duplicates in."))
                }
                if model.confirmedApart > 0 {
                    caption(Loc.t("Модель подтвердила «не дубли»: \(model.confirmedApart)",
                                  "Confirmed not duplicates: \(model.confirmedApart)"))
                }
            }
            switch model.phase {
            case .scanning:
                if model.scan.total == 0 {
                    ActivityLine()                                       // reading the cards: total unknown yet
                } else {
                    ProgressLine(done: model.scan.fraction)
                }
                caption(model.scan.total == 0
                        ? Loc.t("Читаю карточки…", "Reading the cards…")
                        : Loc.t("Проверено фраз: \(model.scan.checked) из \(model.scan.total)",
                                "Phrases checked: \(model.scan.checked) of \(model.scan.total)"))
            case .found:
                if !model.shownGroups.isEmpty {
                    caption(Loc.t("Фразы, которые пишутся похоже (без учёта «to», артиклей, знаков и форм слова; «sb», «smb» и «someone» — одно и то же, но фраза с «someone» и без — разные). Похожие — ещё не одинаковые: точные дубли (та же фраза и тот же перевод) можно слить сразу, остальное проверит модель — какие карточки одно и то же, какие — разные значения одной фразы, а какие — разные фразы. «Не сливать» отмечает карточки как не дубли, и следующий поиск их не предложит.",
                                  "Phrases written alike (ignoring \"to\", articles, punctuation and word forms; \"sb\", \"smb\" and \"someone\" are one, but a phrase with \"someone\" and one without are two). Alike isn't the same: exact duplicates (the same phrase and translation) can be merged right away; the model checks the rest — which cards are one, which are one phrase's meanings, which are different phrases. \"Don't merge\" marks the cards as not duplicates, and the next search leaves them be."))
                }
                if !model.unchecked.isEmpty {
                    let count = model.unchecked.count
                    EHButton(Loc.t("Проверить все для слияния (\(count))", "Check all for merge (\(count))",
                                   "Tout vérifier pour fusion (\(count))", "Revisar todo para unir (\(count))",
                                   "Alle zum Zusammenführen prüfen (\(count))", "Controlla tutto per unire (\(count))"),
                             icon: "sparkles", kind: .primary, fillWidth: true,
                             accessibilityID: "dups.check") { check { model.startCheck() } }
                        .disabled(model.mergeAll != nil)                 // "Merge all" first: it changes the groups
                        .padding(.top, Tokens.Space.s4)
                }
                if model.merged > 0 {
                    caption(Loc.t("Слито: \(model.merged)", "Merged: \(model.merged)"))
                }
            case .checking, .checked, .stopped, .failed:
                if model.check.total > 0 {
                    ProgressLine(done: fraction(model.check.answered), pending: fraction(model.check.sent))
                    ProgressLineLegend(pending: Loc.t("отправлено", "sent", "envoyées", "enviadas", "gesendet", "inviate"),
                                       done: Loc.t("проверено", "checked", "vérifiées", "revisadas", "geprüft", "controllate"))
                    caption(Loc.t("Групп проверено: \(model.check.answered) из \(model.check.total)",
                                  "Groups checked: \(model.check.answered) of \(model.check.total)"))
                }
                if model.merged > 0 {
                    caption(Loc.t("Слито: \(model.merged)", "Merged: \(model.merged)"))
                }
                if model.check.failed > 0 {
                    caption(Loc.t("Модель не ответила по \(model.check.failed) — их можно проверить ещё раз.",
                                  "No answer for \(model.check.failed) — you can check them again."))
                }
                // Also while a group's own Check is out: the rest can join the same line.
                if model.mergeAll == nil, !model.notAsked.isEmpty, model.check.total > 0 {
                    EHButton(Loc.t("Проверить оставшиеся (\(model.notAsked.count))",
                                   "Check the rest (\(model.notAsked.count))"),
                             icon: "sparkles", kind: .tonal, fillWidth: true,
                             accessibilityID: "dups.check") { check { model.startCheck() } }
                }
            }
            if model.phase != .scanning {
                ScanStatistics(model: model) { showSettled = true }
            }
            if let error = model.errorMessage { caption(error) }
            if !model.isBusy {
                EHButton(Loc.t("Полная перепроверка", "Full re-check", "Revérification complète", "Revisión completa",
                               "Vollständige Neuprüfung", "Ricontrollo completo"),
                         icon: "arrow.clockwise", kind: .ghost, fillWidth: true,
                         accessibilityID: "dups.full") { model.rescanFully() }
                caption(Loc.t("Ищет заново, не учитывая отметки «не дубли», — например, после изменения поиска.",
                              "Searches again ignoring the \"not duplicates\" marks — after the matching changed, say."))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
        .padding(.top, Tokens.Space.s8)
    }

    /// The check asks the model: Pro (the search and exact merges are on the device, free).
    private func check(_ run: () -> Void) {
        if subscription.tier.canCheckDuplicates { run() } else { showPaywall = true }
    }

    private var title: String {
        switch model.phase {
        case .scanning: Loc.t("Ищу похожие фразы…", "Looking for look-alikes…")
        case .found:
            if !model.shownGroups.isEmpty {
                Loc.t("Похожих групп: \(model.shownGroups.count)", "Look-alike groups: \(model.shownGroups.count)")
            } else if !model.unchecked.isEmpty {
                Loc.t("Групп на перепроверку: \(model.unchecked.count)", "Groups to re-check: \(model.unchecked.count)")
            } else {
                Loc.t("Все группы разобраны", "Every group is sorted out")
            }
        case .checking: Loc.t("Модель проверяет группы…", "The model is checking the groups…")
        case .checked:
            if !model.shownGroups.isEmpty {
                Loc.t("Проверено — решите по каждой группе", "Checked — decide on each group")
            } else if !model.unchecked.isEmpty {
                Loc.t("Проверены не все группы", "Not every group was checked")
            } else if model.merged > 0 {
                Loc.t("Все группы разобраны", "Every group is sorted out")
            } else {
                Loc.t("Дублей не найдено", "No duplicates found")
            }
        case .stopped: Loc.t("Остановлено", "Stopped")
        case .failed: Loc.t("Не удалось проверить", "Couldn't check")
        }
    }

    private func fraction(_ count: Int) -> Double {
        model.check.total == 0 ? 0 : Double(count) / Double(model.check.total)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .textStyle(Tokens.Text.subhead)
            .foregroundStyle(Tokens.Content.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One look-alike group: its phrases with their progress, the card(s) a merge would make, and two
/// buttons — Merge (Check while nobody has checked it) and Don't merge.
private struct GroupCard: View {
    let group: DuplicateGroup
    let proposals: [DuplicateMerge]
    let isChecked: Bool
    /// A phrase in no proposal stays apart (the model checked the group, or it's only exact duplicates).
    let isSettled: Bool
    let isBusy: Bool
    /// The running Check has asked the model about this group: Merge / Check wait for the answer.
    let isAwaited: Bool
    let onMerge: () -> Void
    let onCheck: () -> Void
    let onKeepApart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            HStack(spacing: Tokens.Space.s8) {
                chip(status)
                if group.isAllMarked {
                    chip(Loc.t("Отмечены «не дубли»", "Marked \"not duplicates\"", "Marquées « pas des doublons »",
                               "Marcadas «no duplicados»", "Als „keine Duplikate“ markiert", "Segnate «non duplicati»"))
                }
            }

            ForEach(shownMembers) { expression in
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    Text(expression.en)
                        .textStyle(Tokens.Text.headline)
                        .foregroundStyle(Tokens.Content.primary)
                    Text(expression.ru)
                        .textStyle(Tokens.Text.subhead)
                        .foregroundStyle(Tokens.Content.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Tokens.Space.s4) { tags(for: expression) }
                        VStack(alignment: .leading, spacing: Tokens.Space.s4) { tags(for: expression) }
                    }
                    if isSettled, !proposals.isEmpty, !proposals.contains(where: { $0.expressionIDs.contains(expression.id) }) {
                        Text(Loc.t("Другая фраза — не сольётся", "Another phrase — won't be merged",
                                   "Autre expression — ne sera pas fusionnée", "Otra frase — no se unirá",
                                   "Anderer Ausdruck — wird nicht zusammengeführt", "Altra frase — non verrà unita"))
                            .textStyle(Tokens.Text.footnote)
                            .foregroundStyle(Tokens.Content.tertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if !settledMembers.isEmpty {
                // Cards already marked "not duplicates" of each other: context, not the question.
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    Text(Loc.t("Уже отмечены как не дубли друг другу:", "Already marked not duplicates of each other:",
                               "Déjà marquées comme non doublons :", "Ya marcadas como no duplicadas:",
                               "Schon als keine Duplikate markiert:", "Già segnate come non duplicati:"))
                        .textStyle(Tokens.Text.caption)
                        .foregroundStyle(Tokens.Content.tertiary)
                    Text(settledMembers.map { "«\($0.en)»" }.joined(separator: ", "))
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Content.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("dups.settled")
            }

            ForEach(proposals) { merge in
                proposal(merge)
            }

            if isBusy {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                HStack(spacing: Tokens.Space.s8) {
                    if !proposals.isEmpty {
                        EHButton(Loc.t("Слить", "Merge", "Fusionner", "Unir", "Zusammenführen", "Unisci"),
                                 icon: "arrow.triangle.merge", kind: .primary, fillWidth: true,
                                 accessibilityID: "dups.merge", action: onMerge)
                            .disabled(isAwaited)
                    } else if !isChecked {
                        EHButton(Loc.t("Проверить", "Check", "Vérifier", "Revisar", "Prüfen", "Controlla"),
                                 icon: "sparkles", kind: .primary, fillWidth: true,
                                 accessibilityID: "dups.checkGroup", action: onCheck)
                            .disabled(isAwaited)
                    }
                    EHButton(Loc.t("Не сливать", "Don't merge", "Ne pas fusionner", "No unir", "Nicht zusammenführen",
                                   "Non unire"),
                             kind: proposals.isEmpty && isChecked ? .primary : .tonal, fillWidth: true,
                             accessibilityID: "dups.keep", action: onKeepApart)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    /// The cards the question is about. In a normal search, a group that joins cards already marked
    /// "not duplicates" of each other with new look-alikes asks about the new ones; the marked ones
    /// are shown as a line of context (`settledMembers`).
    private var shownMembers: [Domain.Expression] {
        settledMembers.isEmpty ? group.expressions : group.expressions.filter { !markedIDs.contains($0.id) }
    }

    private var settledMembers: [Domain.Expression] {
        guard group.honorsMarks, !group.marked.isEmpty,
              group.expressions.contains(where: { !markedIDs.contains($0.id) }) else { return [] }
        return group.expressions.filter { markedIDs.contains($0.id) }
    }

    private var markedIDs: Set<UUID> {
        Set(group.marked.flatMap { [$0.first, $0.second] })
    }

    /// A proposed merge: what it joins and the card it makes.
    private func proposal(_ merge: DuplicateMerge) -> some View {
        let names = group.expressions.filter { merge.expressionIDs.contains($0.id) }.map { "«\($0.en)»" }
        return VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Text(kindLabel(merge))
                .textStyle(Tokens.Text.caption)
                .foregroundStyle(Tokens.Content.tertiary)
            Text(names.joined(separator: " + "))
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.secondary)
            Text(merge.card.expression)
                .textStyle(Tokens.Text.headline)
                .foregroundStyle(Tokens.Content.primary)
                .padding(.top, Tokens.Space.s4)
            Text(merge.card.translation)
                .textStyle(Tokens.Text.subhead)
                .foregroundStyle(Tokens.Content.primary)
            if !merge.card.example.isEmpty {
                Text(merge.card.example)
                    .textStyle(Tokens.Text.subhead)
                    .italic()
                    .foregroundStyle(Tokens.Content.secondary)
            }
            if !merge.card.synonyms.isEmpty {
                Text(merge.card.synonyms.joined(separator: ", "))
                    .textStyle(Tokens.Text.footnote)
                    .foregroundStyle(Tokens.Content.secondary)
            }
            if !merge.card.context.isEmpty {
                Text(merge.card.context)
                    .textStyle(Tokens.Text.footnote)
                    .foregroundStyle(Tokens.Content.tertiary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(Tokens.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Fill.subtle, in: RoundedRectangle(cornerRadius: Tokens.Radius.card / 2))
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .textStyle(Tokens.Text.caption)
            .foregroundStyle(Tokens.Content.secondary)
            .padding(.horizontal, Tokens.Space.s8)
            .padding(.vertical, 3)
            .background(Tokens.Fill.subtle, in: Capsule())
    }

    @ViewBuilder private func tags(for expression: Domain.Expression) -> some View {
        ForEach((group.cards[expression.id] ?? []).sorted { $0.direction == .recognition && $1.direction != .recognition }) {
            CardStatusTag(card: $0)
        }
    }

    private var status: String {
        if isAwaited {
            return Loc.t("Модель проверяет…", "The model is checking…", "Le modèle vérifie…", "El modelo revisa…",
                         "Das Modell prüft…", "Il modello controlla…")
        }
        if isChecked {
            return proposals.isEmpty
                ? Loc.t("Разные фразы", "Different phrases", "Expressions différentes", "Frases distintas",
                        "Verschiedene Ausdrücke", "Frasi diverse")
                : Loc.t("Проверено моделью", "Checked by the model", "Vérifié par le modèle", "Revisado por el modelo",
                        "Vom Modell geprüft", "Controllato dal modello")
        }
        if group.isExactOnly {
            return Loc.t("Точный дубль", "Exact duplicate", "Doublon exact", "Duplicado exacto", "Exaktes Duplikat",
                         "Duplicato esatto")
        }
        return Loc.t("Ещё не проверено", "Not checked yet", "Pas encore vérifié", "Aún sin revisar",
                     "Noch nicht geprüft", "Non ancora controllato")
    }

    private func kindLabel(_ merge: DuplicateMerge) -> String {
        switch (merge.kind, merge.isExact) {
        case (.duplicate, true): Loc.t("Точный дубль — та же фраза и перевод. Получится:",
                                       "Exact duplicate — the same phrase and translation. Merged:")
        case (.duplicate, false): Loc.t("Дубль — одна фраза, один смысл. Получится:",
                                        "Duplicate — one phrase, one meaning. Merged:")
        case (.senses, _): Loc.t("Одна фраза, разные значения — одна карточка с нумерацией:",
                                 "One phrase, several meanings — one card, numbered:")
        }
    }
}

/// After a search: how many phrases it read, how many look-alike candidates it found, and how many were
/// already marked "not duplicates" — that line opens the list of them.
private struct ScanStatistics: View {
    let model: DuplicatesViewModel
    let onOpenSettled: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            row(Loc.t("Проверено фраз", "Phrases checked", "Expressions vérifiées", "Frases revisadas",
                      "Geprüfte Phrasen", "Frasi controllate"), "\(model.phrasesChecked)")
            row(Loc.t("Кандидаты в дубли", "Duplicate candidates", "Doublons possibles", "Posibles duplicados",
                      "Mögliche Duplikate", "Possibili duplicati"),
                Loc.t("групп: \(model.candidateGroups) · фраз: \(model.candidatePhrases)",
                      "groups: \(model.candidateGroups) · phrases: \(model.candidatePhrases)"))
            if !model.isFull {
                Button(action: onOpenSettled) {
                    HStack {
                        row(Loc.t("Отмечены как не дубли", "Marked not duplicates", "Marquées non doublons",
                                  "Marcadas no duplicados", "Als keine Duplikate markiert", "Segnate non duplicati"),
                            Loc.t("групп: \(model.settled.count) · фраз: \(model.settledPhrases)",
                                  "groups: \(model.settled.count) · phrases: \(model.settledPhrases)"))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tokens.Content.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.settled.isEmpty)
                .accessibilityIdentifier("dups.settledList")
            }
        }
        .padding(.top, Tokens.Space.s4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dups.stats")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(Tokens.Content.secondary)
            Spacer(minLength: Tokens.Space.s8)
            Text(value)
                .foregroundStyle(Tokens.Content.primary)
                .monospacedDigit()
        }
        .textStyle(Tokens.Text.subhead)
        .accessibilityElement(children: .combine)
    }
}

/// The groups already marked "not duplicates": each with its phrases, "Take the mark off" (the group
/// joins the candidates) and "Merge" (exact — at once; otherwise the model's card, to confirm on the list).
private struct SettledGroupsView: View {
    let model: DuplicatesViewModel
    let onMerge: (DuplicateGroup) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Tokens.Space.s12) {
                if model.settled.isEmpty {
                    Text(Loc.t("Отмеченных групп не осталось.", "No marked groups left."))
                        .textStyle(Tokens.Text.subhead)
                        .foregroundStyle(Tokens.Content.secondary)
                        .padding(.top, Tokens.Space.s24)
                }
                ForEach(model.settled) { group in
                    VStack(alignment: .leading, spacing: Tokens.Space.s12) {
                        ForEach(group.expressions) { expression in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(expression.en)
                                    .textStyle(Tokens.Text.headline)
                                    .foregroundStyle(Tokens.Content.primary)
                                Text(expression.ru)
                                    .textStyle(Tokens.Text.subhead)
                                    .foregroundStyle(Tokens.Content.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        HStack(spacing: Tokens.Space.s8) {
                            EHButton(Loc.t("Снять пометку", "Unmark", "Retirer la marque", "Quitar la marca",
                                           "Markierung entfernen", "Togli il segno"),
                                     kind: .tonal, fillWidth: true, accessibilityID: "settled.unmark") {
                                model.unmark(group)
                            }
                            EHButton(Loc.t("Слить", "Merge", "Fusionner", "Unir", "Zusammenführen", "Unisci"),
                                     icon: "arrow.triangle.merge", kind: .primary, fillWidth: true,
                                     accessibilityID: "settled.merge") {
                                onMerge(group)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Space.s16)
                    .glassPanel(cornerRadius: Tokens.Radius.card)
                }
                Text(Loc.t("«Снять пометку» и «Слить» без точного дубля возвращают группу в список кандидатов: там её можно слить, проверить моделью или снова отметить.",
                           "Unmark — and Merge without an exact duplicate — put the group back on the list of candidates: merge it there, check it with the model, or mark it again."))
                    .textStyle(Tokens.Text.footnote)
                    .foregroundStyle(Tokens.Content.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Tokens.Space.s16)
            .padding(.vertical, Tokens.Space.s8)
        }
        .background(Tokens.Surface.background)
        .navigationTitle(Loc.t("Не дубли", "Not duplicates", "Non doublons", "No duplicados", "Keine Duplikate",
                               "Non duplicati"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
