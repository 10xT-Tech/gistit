//
//  IncompleteCardsView.swift
//  EnglishHelper — Presentation
//
//  The incomplete cards, pushed from the Fix cards sheet: "To fix" (the model hasn't answered for them)
//  and "Nothing to add" (it answered and left a field empty — no synonyms fit "an elbow"). Each row shows
//  what's missing and a Fix button that sends the card to the model alone; below it, what came of it —
//  filled in, nothing to add, or the error with its detail (selectable, to pass on).
//

import SwiftUI
import Domain
import DesignSystem

struct IncompleteCardsView: View {
    let model: IncompleteCardsViewModel
    let onSubscribe: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s12) {
                if model.isLoading && model.cards.isEmpty {
                    ActivityLine().padding(.top, Tokens.Space.s16)
                } else if let error = model.loadError {
                    caption(error)
                } else if model.cards.isEmpty {
                    caption(Loc.t("Все карточки заполнены.", "Every card is complete."))
                        .padding(.top, Tokens.Space.s16)
                        .accessibilityIdentifier("incomplete.none")
                }
                section(Loc.t("Нужно исправить", "To fix", "À corriger", "Por corregir", "Zu korrigieren", "Da correggere"),
                        note: Loc.t("Модель по ним ещё не отвечала.", "The model hasn't answered for these yet."),
                        cards: model.toFix)
                section(Loc.t("Модели нечего добавить", "Nothing to add", "Rien à ajouter", "Nada que añadir",
                              "Nichts hinzuzufügen", "Niente da aggiungere"),
                        note: Loc.t("Модель ответила и оставила поле пустым — например, у слова нет синонимов. В «Только неполные» они больше не попадают; исправить вручную можно всегда.",
                                    "The model answered and left the field empty — a word with no synonyms, say. \"Only incomplete\" leaves them out now; you can always fix one by hand."),
                        cards: model.nothingToAdd)
            }
            .padding(.horizontal, Tokens.Space.s16)
            .padding(.bottom, Tokens.Space.s24)
        }
        .background(Tokens.Surface.background)
        .navigationTitle(Loc.t("Неполные карточки", "Incomplete cards", "Cartes incomplètes", "Tarjetas incompletas",
                               "Unvollständige Karten", "Carte incomplete"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    @ViewBuilder
    private func section(_ title: String, note: String, cards: [IncompleteCard]) -> some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                Text("\(title) · \(cards.count)")
                    .textStyle(Tokens.Text.headline)
                    .foregroundStyle(Tokens.Content.primary)
                caption(note)
            }
            .padding(.top, Tokens.Space.s12)
            ForEach(cards) { card in
                IncompleteCardRow(card: card, status: model.status(of: card),
                                  onFix: { model.fix(card) }, onSubscribe: onSubscribe)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .textStyle(Tokens.Text.footnote)
            .foregroundStyle(Tokens.Content.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct IncompleteCardRow: View {
    let card: IncompleteCard
    let status: IncompleteCardsViewModel.RowStatus?
    let onFix: () -> Void
    let onSubscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.expression.en)
                        .textStyle(Tokens.Text.headline)
                        .foregroundStyle(Tokens.Content.primary)
                    Text(card.expression.ru)
                        .textStyle(Tokens.Text.subhead)
                        .foregroundStyle(Tokens.Content.secondary)
                }
                Spacer(minLength: Tokens.Space.s8)
                if status == .fixing {
                    ProgressView().controlSize(.small)
                } else if status != .filled {
                    Button(action: onFix) {
                        Label(Loc.t("Исправить", "Fix", "Corriger", "Corregir", "Korrigieren", "Correggi"),
                              systemImage: "wand.and.stars")
                            .textStyle(Tokens.Text.subhead)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("incomplete.fix")
                }
            }
            if status != .filled {
                HStack(spacing: Tokens.Space.s4) {
                    ForEach(card.missing, id: \.self) { field in
                        Text(Self.missingTitle(field))
                            .textStyle(Tokens.Text.caption)
                            .foregroundStyle(Tokens.Content.secondary)
                            .padding(.horizontal, Tokens.Space.s8)
                            .padding(.vertical, 3)
                            .background(Tokens.Fill.subtle, in: Capsule())
                    }
                }
            }
            if let status { statusLine(status) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("incomplete.row")
    }

    @ViewBuilder
    private func statusLine(_ status: IncompleteCardsViewModel.RowStatus) -> some View {
        switch status {
        case .fixing:
            EmptyView()
        case .filled:
            Label(Loc.t("Заполнено — карточка полная", "Filled in — the card is complete"), systemImage: "checkmark.circle")
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Signal.success)
                .accessibilityIdentifier("incomplete.filled")
        case .nothingToAdd(let missing):
            Text(Loc.t("Модель ответила, но оставила пустым: \(missing.map(Self.fieldName).joined(separator: ", ")) — подходящего нет.",
                       "The model answered but left empty: \(missing.map(Self.fieldName).joined(separator: ", ")) — nothing fits."))
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("incomplete.nothing")
        case .failed(let message, let detail, let needsSubscription):
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .textStyle(Tokens.Text.footnote)
                    .foregroundStyle(Tokens.Content.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .textStyle(Tokens.Text.caption)
                    .foregroundStyle(Tokens.Content.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if needsSubscription {
                    Button(Loc.t("Оформить подписку", "Subscribe"), action: onSubscribe)
                        .textStyle(Tokens.Text.footnote)
                }
            }
            .accessibilityIdentifier("incomplete.error")
        }
    }

    static func missingTitle(_ field: CardField) -> String {
        switch field {
        case .example: Loc.t("нет примера", "no example", "pas d'exemple", "sin ejemplo", "kein Beispiel", "nessun esempio")
        case .synonyms: Loc.t("нет синонимов", "no synonyms", "pas de synonymes", "sin sinónimos", "keine Synonyme", "nessun sinonimo")
        case .note: Loc.t("нет пояснения", "no note", "pas de note", "sin nota", "keine Notiz", "nessuna nota")
        }
    }

    static func fieldName(_ field: CardField) -> String {
        switch field {
        case .example: Loc.t("пример", "example", "exemple", "ejemplo", "Beispiel", "esempio")
        case .synonyms: Loc.t("синонимы", "synonyms", "synonymes", "sinónimos", "Synonyme", "sinonimi")
        case .note: Loc.t("пояснение", "note", "note", "nota", "Notiz", "nota")
        }
    }
}
