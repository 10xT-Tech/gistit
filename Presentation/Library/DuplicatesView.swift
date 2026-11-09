//
//  DuplicatesView.swift
//  EnglishHelper — Presentation
//
//  The "Find duplicates" sheet: reading the phrases (a progress line), how many look-alike groups
//  there are and "Check" (the model), then the check's two-part line — sent in grey, answered in
//  green catching up — over the groups: each with its phrases and their progress, the model's verdict
//  and the card it would make, and Merge / Keep apart. "Merge all duplicates" takes the clear cases at
//  once. The paywall is presented from here (a second sheet can't open from the root).
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
                    if !model.duplicateGroups.isEmpty {
                        EHButton(Loc.t("Объединить все дубли (\(model.duplicateGroups.count))",
                                       "Merge all duplicates (\(model.duplicateGroups.count))",
                                       "Fusionner tous les doublons (\(model.duplicateGroups.count))",
                                       "Unir todos los duplicados (\(model.duplicateGroups.count))",
                                       "Alle Duplikate zusammenführen (\(model.duplicateGroups.count))",
                                       "Unisci tutti i duplicati (\(model.duplicateGroups.count))"),
                                 icon: "arrow.triangle.merge", kind: .tonal, fillWidth: true,
                                 accessibilityID: "dups.mergeAll") { model.mergeAllDuplicates() }
                            .disabled(!model.merging.isEmpty)
                    }
                    ForEach(model.groups) { group in
                        GroupCard(group: group, verdict: model.verdicts[group.id],
                                  isMerging: model.merging.contains(group.id),
                                  onMerge: { model.merge(group) }, onKeepApart: { model.keepApart(group) })
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
            switch model.phase {
            case .scanning:
                ProgressLine(done: model.scan.fraction)
                caption(model.scan.total == 0
                        ? Loc.t("Читаю карточки…", "Reading the cards…")
                        : Loc.t("Проверено фраз: \(model.scan.checked) из \(model.scan.total)",
                                "Phrases checked: \(model.scan.checked) of \(model.scan.total)"))
            case .found:
                caption(Loc.t("Фразы, которые пишутся одинаково (без учёта «to», артиклей, «someone», знаков и форм слова). Модель проверит каждую группу — один и тот же смысл, разные значения или разные фразы — и предложит объединённую карточку. Решаете вы.",
                              "Phrases written alike (ignoring \"to\", articles, \"someone\", punctuation and word forms). The model checks each group — the same meaning twice, several meanings or different phrases — and proposes the merged card. You decide."))
                EHButton(Loc.t("Проверить (\(model.unchecked.count))", "Check (\(model.unchecked.count))",
                               "Vérifier (\(model.unchecked.count))", "Revisar (\(model.unchecked.count))",
                               "Prüfen (\(model.unchecked.count))", "Controlla (\(model.unchecked.count))"),
                         icon: "sparkles", kind: .primary, fillWidth: true,
                         accessibilityID: "dups.check") { model.startCheck() }
                    .padding(.top, Tokens.Space.s4)
            case .checking, .checked, .stopped, .failed:
                if model.check.total > 0 {
                    ProgressLine(done: fraction(model.check.answered), pending: fraction(model.check.sent))
                    ProgressLineLegend(pending: Loc.t("отправлено", "sent", "envoyées", "enviadas", "gesendet", "inviate"),
                                       done: Loc.t("проверено", "checked", "vérifiées", "revisadas", "geprüft", "controllate"))
                    caption(Loc.t("Групп проверено: \(model.check.answered) из \(model.check.total)",
                                  "Groups checked: \(model.check.answered) of \(model.check.total)"))
                }
                if model.merged > 0 {
                    caption(Loc.t("Объединено: \(model.merged)", "Merged: \(model.merged)"))
                }
                if model.check.failed > 0 {
                    caption(Loc.t("Модель не ответила по \(model.check.failed) — их можно проверить ещё раз.",
                                  "No answer for \(model.check.failed) — you can check them again."))
                }
                if let error = model.errorMessage { caption(error) }
                if !model.isBusy, !model.unchecked.isEmpty, model.check.total > 0 {
                    EHButton(Loc.t("Проверить оставшиеся (\(model.unchecked.count))",
                                   "Check the rest (\(model.unchecked.count))"),
                             icon: "sparkles", kind: .tonal, fillWidth: true,
                             accessibilityID: "dups.check") { model.startCheck() }
                }
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
        case .found: Loc.t("Похожих групп: \(model.groups.count)", "Look-alike groups: \(model.groups.count)")
        case .checking: Loc.t("Модель проверяет группы…", "The model is checking the groups…")
        case .checked: model.groups.isEmpty
            ? (model.merged > 0 ? Loc.t("Все группы разобраны", "Every group is sorted out")
                                : Loc.t("Дублей не найдено", "No duplicates found"))
            : Loc.t("Проверено — решите по каждой группе", "Checked — decide on each group")
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

/// One look-alike group: its phrases with their progress, the model's verdict and proposed card, the
/// decision buttons.
private struct GroupCard: View {
    let group: DuplicateGroup
    let verdict: DuplicateVerdict?
    let isMerging: Bool
    let onMerge: () -> Void
    let onKeepApart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            Text(verdictLabel)
                .textStyle(Tokens.Text.caption)
                .foregroundStyle(Tokens.Content.secondary)
                .padding(.horizontal, Tokens.Space.s8)
                .padding(.vertical, 3)
                .background(Tokens.Fill.subtle, in: Capsule())

            ForEach(group.expressions) { expression in
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
                }
                .accessibilityElement(children: .combine)
            }

            if let verdict, verdict.verdict != .different {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    Text(Loc.t("Получится:", "Merged:"))
                        .textStyle(Tokens.Text.caption)
                        .foregroundStyle(Tokens.Content.tertiary)
                    Text(verdict.card.expression)
                        .textStyle(Tokens.Text.headline)
                        .foregroundStyle(Tokens.Content.primary)
                    Text(verdict.card.translation)
                        .textStyle(Tokens.Text.subhead)
                        .foregroundStyle(Tokens.Content.primary)
                    if !verdict.card.example.isEmpty {
                        Text(verdict.card.example)
                            .textStyle(Tokens.Text.subhead)
                            .italic()
                            .foregroundStyle(Tokens.Content.secondary)
                    }
                    if !verdict.card.synonyms.isEmpty {
                        Text(verdict.card.synonyms.joined(separator: ", "))
                            .textStyle(Tokens.Text.footnote)
                            .foregroundStyle(Tokens.Content.secondary)
                    }
                    if !verdict.card.context.isEmpty {
                        Text(verdict.card.context)
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

            if isMerging {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                buttons
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    @ViewBuilder private func tags(for expression: Domain.Expression) -> some View {
        ForEach((group.cards[expression.id] ?? []).sorted { $0.direction == .recognition && $1.direction != .recognition }) {
            CardStatusTag(card: $0)
        }
    }

    @ViewBuilder private var buttons: some View {
        let keepApart = Loc.t("Оставить отдельно", "Keep apart", "Garder séparées", "Mantener separadas",
                              "Getrennt lassen", "Tieni separate")
        if let verdict {
            if verdict.verdict == .different {
                HStack(spacing: Tokens.Space.s8) {
                    EHButton(keepApart, kind: .primary, fillWidth: true, accessibilityID: "dups.keep", action: onKeepApart)
                    EHButton(Loc.t("Всё равно объединить", "Merge anyway"), kind: .ghost, fillWidth: true,
                             accessibilityID: "dups.merge", action: onMerge)
                }
            } else {
                HStack(spacing: Tokens.Space.s8) {
                    EHButton(Loc.t("Объединить", "Merge", "Fusionner", "Unir", "Zusammenführen", "Unisci"),
                             icon: "arrow.triangle.merge", kind: .primary, fillWidth: true,
                             accessibilityID: "dups.merge", action: onMerge)
                    EHButton(keepApart, kind: .tonal, fillWidth: true, accessibilityID: "dups.keep", action: onKeepApart)
                }
            }
        } else {
            EHButton(keepApart, kind: .tonal, fillWidth: true, accessibilityID: "dups.keep", action: onKeepApart)
        }
    }

    private var verdictLabel: String {
        switch verdict?.verdict {
        case .duplicate: Loc.t("Дубль", "Duplicate", "Doublon", "Duplicado", "Duplikat", "Duplicato")
        case .senses: Loc.t("Разные значения", "Several meanings", "Plusieurs sens", "Varios significados",
                            "Mehrere Bedeutungen", "Più significati")
        case .different: Loc.t("Разные фразы", "Different phrases", "Expressions différentes", "Frases distintas",
                               "Verschiedene Ausdrücke", "Frasi diverse")
        case nil: Loc.t("Ещё не проверено", "Not checked yet", "Pas encore vérifié", "Aún sin revisar",
                        "Noch nicht geprüft", "Non ancora controllato")
        }
    }
}
