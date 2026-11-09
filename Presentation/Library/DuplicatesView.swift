//
//  DuplicatesView.swift
//  EnglishHelper — Presentation
//
//  The "Find duplicates" sheet: reading the phrases (a progress line), how many look-alike groups
//  there are and "Check" (the model), then the check's two-part line — sent in grey, answered in
//  green catching up — over the groups: each with its phrases and their progress, the proposed
//  merges (exact duplicates at once, the model's after the check) with the card each makes, and
//  Merge / Keep apart; a phrase in no merge is marked as staying apart. "Merge all duplicates" takes
//  the clear cases at once. The paywall is presented from here (a second sheet can't open from the root).
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
                        EHButton(Loc.t("Объединить все дубли (\(count))", "Merge all duplicates (\(count))",
                                       "Fusionner tous les doublons (\(count))", "Unir todos los duplicados (\(count))",
                                       "Alle Duplikate zusammenführen (\(count))", "Unisci tutti i duplicati (\(count))"),
                                 icon: "arrow.triangle.merge", kind: .tonal, fillWidth: true,
                                 accessibilityID: "dups.mergeAll") { model.mergeAllDuplicates() }
                            .disabled(!model.merging.isEmpty)
                    }
                    ForEach(model.groups) { group in
                        GroupCard(group: group, proposals: model.proposals[group.key] ?? [],
                                  isChecked: model.checkedKeys.contains(group.key), isSettled: model.isSettled(group),
                                  merging: model.merging,
                                  onMerge: { model.merge($0, in: group) }, onKeepApart: { model.keepApart(group) })
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
                if !model.groups.isEmpty {
                    caption(Loc.t("Фразы, которые пишутся похоже (без учёта «to», артиклей, «someone», знаков и форм слова). Похожие — ещё не одинаковые: точные дубли (та же фраза и тот же перевод) можно объединить сразу, остальное проверит модель — какие карточки одно и то же, какие — разные значения одной фразы, а какие — разные фразы. Решаете вы.",
                                  "Phrases written alike (ignoring \"to\", articles, \"someone\", punctuation and word forms). Alike isn't the same: exact duplicates (the same phrase and translation) can be merged right away; the model checks the rest — which cards are one, which are one phrase's meanings, which are different phrases. You decide."))
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
                    caption(Loc.t("Объединено: \(model.merged)", "Merged: \(model.merged)"))
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
        case .found: model.groups.isEmpty
            ? Loc.t("Все группы разобраны", "Every group is sorted out")
            : Loc.t("Похожих групп: \(model.groups.count)", "Look-alike groups: \(model.groups.count)")
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

/// One look-alike group: its phrases with their progress, the proposed merges with the card each
/// makes, the decision buttons.
private struct GroupCard: View {
    let group: DuplicateGroup
    let proposals: [DuplicateMerge]
    let isChecked: Bool
    /// A phrase in no proposal stays apart (the model checked the group, or it's only exact duplicates).
    let isSettled: Bool
    let merging: Set<String>
    let onMerge: (DuplicateMerge) -> Void
    let onKeepApart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            chip(status)

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
                    if isSettled, !proposals.isEmpty, !proposals.contains(where: { $0.expressionIDs.contains(expression.id) }) {
                        Text(Loc.t("Другая фраза — останется отдельно", "Another phrase — stays apart",
                                   "Autre expression — reste à part", "Otra frase — queda aparte",
                                   "Anderer Ausdruck — bleibt getrennt", "Altra frase — resta a parte"))
                            .textStyle(Tokens.Text.footnote)
                            .foregroundStyle(Tokens.Content.tertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            ForEach(proposals) { merge in
                proposal(merge)
            }

            EHButton(proposals.isEmpty ? keepApart
                                       : Loc.t("Оставить все отдельно", "Keep all apart", "Tout garder séparé",
                                               "Mantener todo aparte", "Alle getrennt lassen", "Tieni tutto separato"),
                     kind: .tonal, fillWidth: true, accessibilityID: "dups.keep", action: onKeepApart)
                .disabled(!merging.isDisjoint(with: proposals.map(\.id)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    /// A proposed merge: what it joins, the card it makes, Merge.
    private func proposal(_ merge: DuplicateMerge) -> some View {
        let names = group.expressions.filter { merge.expressionIDs.contains($0.id) }.map { "«\($0.en)»" }
        return VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
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
            .accessibilityElement(children: .combine)
            if merging.contains(merge.id) {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                EHButton(Loc.t("Объединить (\(merge.expressionIDs.count))", "Merge (\(merge.expressionIDs.count))",
                               "Fusionner (\(merge.expressionIDs.count))", "Unir (\(merge.expressionIDs.count))",
                               "Zusammenführen (\(merge.expressionIDs.count))", "Unisci (\(merge.expressionIDs.count))"),
                         icon: "arrow.triangle.merge", kind: .primary, fillWidth: true,
                         accessibilityID: "dups.merge") { onMerge(merge) }
            }
        }
        .padding(Tokens.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Fill.subtle, in: RoundedRectangle(cornerRadius: Tokens.Radius.card / 2))
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

    private var keepApart: String {
        Loc.t("Оставить отдельно", "Keep apart", "Garder séparées", "Mantener separadas", "Getrennt lassen", "Tieni separate")
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
        case (.duplicate, true): Loc.t("Точный дубль — та же фраза и перевод", "Exact duplicate — the same phrase and translation")
        case (.duplicate, false): Loc.t("Дубль — одна фраза, один смысл", "Duplicate — one phrase, one meaning")
        case (.senses, _): Loc.t("Одна фраза, разные значения — одна карточка с нумерацией",
                                 "One phrase, several meanings — one card, numbered")
        }
    }
}
