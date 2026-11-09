//
//  DuplicatesView.swift
//  EnglishHelper — Presentation
//
//  The "Find duplicates" sheet: reading the phrases (a progress line), how many look-alike groups
//  there are and "Check" (the model), then the check's two-part line — sent in grey, answered in
//  green catching up — over the groups: each with its phrases and their progress, the proposed
//  merges (exact duplicates at once, the model's after the check) with the card each makes, and two
//  buttons — Merge / Don't merge ("not duplicates", kept with the cards); a group nobody checked yet
//  offers Check instead of Merge. "Merge all duplicates" takes the clear cases at once; "Full
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
                    if !model.duplicateMerges.isEmpty {
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
                                  isBusy: model.busy.contains(group.key),
                                  onMerge: { model.mergeGroup(group) }, onCheck: { model.checkGroup(group) },
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
        }
        .interactiveDismissDisabled(model.phase == .checking)
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
                    EHButton(Loc.t("Проверить (\(model.unchecked.count))", "Check (\(model.unchecked.count))",
                                   "Vérifier (\(model.unchecked.count))", "Revisar (\(model.unchecked.count))",
                                   "Prüfen (\(model.unchecked.count))", "Controlla (\(model.unchecked.count))"),
                             icon: "sparkles", kind: .primary, fillWidth: true,
                             accessibilityID: "dups.check") { model.startCheck() }
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
                if !model.isBusy, !model.unchecked.isEmpty, model.check.total > 0 {
                    EHButton(Loc.t("Проверить оставшиеся (\(model.unchecked.count))",
                                   "Check the rest (\(model.unchecked.count))"),
                             icon: "sparkles", kind: .tonal, fillWidth: true,
                             accessibilityID: "dups.check") { model.startCheck() }
                }
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
                    } else if !isChecked {
                        EHButton(Loc.t("Проверить", "Check", "Vérifier", "Revisar", "Prüfen", "Controlla"),
                                 icon: "sparkles", kind: .primary, fillWidth: true,
                                 accessibilityID: "dups.checkGroup", action: onCheck)
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
