//
//  NewCardSheet.swift
//  EnglishHelper — Presentation
//
//  Caught → "Generate from a phrase": one card to fill in — the phrase (two lines, focused at once) and,
//  under a hairline, an optional context — then Generate. The translation, an example, synonyms and a
//  note are filled in by the model. Return in the phrase moves on to the context; in the context it
//  generates.
//

import SwiftUI
import Domain
import DesignSystem

struct NewCardSheet: View {
    @Bindable var model: StudyListViewModel
    @FocusState private var focus: Field?

    private enum Field { case phrase, context }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s16) {
                    if model.needsAPIKey {
                        HStack(spacing: Tokens.Space.s8) {
                            Image(systemName: "key.slash").foregroundStyle(Tokens.Signal.warning)
                            Text(Loc.t("Без ключа Claude API карточка сохранится без перевода и примеров.",
                                       "Without a Claude API key, the card is saved without translation or examples."))
                                .textStyle(Tokens.Text.footnote)
                                .foregroundStyle(Tokens.Content.secondary)
                        }
                    }

                    card

                    Label(Loc.t("Перевод, пример, синонимы и пояснение заполнятся сами.",
                                "The translation, an example, synonyms and a note are filled in for you."),
                          systemImage: "sparkles")
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Content.tertiary)

                    if let addError = model.addError {
                        Text(addError)
                            .textStyle(Tokens.Text.footnote)
                            .foregroundStyle(Tokens.Signal.error)
                    }

                    if model.isAdding {
                        LoadingView(Loc.t("Дополняю переводом и примерами…", "Adding translation and examples…"))
                    } else {
                        EHButton(Loc.t("Сгенерировать карточку", "Generate the card"), icon: "sparkles", kind: .primary,
                                 fillWidth: true, accessibilityID: "newCard.generate") {
                            model.add()
                        }
                        .disabled(!model.canAdd)   // EHButton dims itself when disabled
                    }
                }
                .padding(Tokens.Space.s20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Tokens.Surface.background)
            .navigationTitle(Loc.t("Новая карточка", "New card"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(Loc.t("Отмена", "Cancel")) { model.showAddSheet = false }
                }
            }
            .onAppear { focus = .phrase }
        }
        .presentationDetents([.large])
    }

    /// The phrase and the context on one card, a hairline between them.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            field(label: Loc.t("Фраза на изучаемом языке", "A phrase in the language you're learning"),
                  placeholder: Loc.t("например, to hit the roof", "e.g. to hit the roof"),
                  text: $model.newEnglish, lines: 2...4, style: Tokens.Text.title3, field: .phrase,
                  accessibilityID: "newCard.phrase")
            Rectangle()
                .fill(Tokens.Hairline.default)
                .frame(height: Tokens.Hairline.width)
                .padding(.leading, Tokens.Space.s16)
            field(label: Loc.t("Контекст — необязательно", "Context — optional"),
                  placeholder: Loc.t("где встретили, что хотите уточнить", "where you met it, what to make clear"),
                  text: $model.newContext, lines: 1...3, style: Tokens.Text.body, field: .context,
                  accessibilityID: "newCard.context")
        }
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    private func field(label: String, placeholder: String, text: Binding<String>, lines: ClosedRange<Int>,
                       style: Tokens.TextStyleToken, field: Field, accessibilityID: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Text(label)
                .textStyle(Tokens.Text.caption)
                .foregroundStyle(Tokens.Content.secondary)
            HStack(alignment: .top, spacing: Tokens.Space.s8) {
                TextField(placeholder, text: text, axis: .vertical)
                    .lineLimit(lines)                       // at least the lower bound: two lines for the phrase
                    .textStyle(style)
                    .foregroundStyle(Tokens.Content.primary)
                    .focused($focus, equals: field)
                    .submitLabel(field == .phrase ? .next : .go)
                    .accessibilityIdentifier(accessibilityID)
                    // A vertical field takes Return as a new line: here it moves on, or generates.
                    .onChange(of: text.wrappedValue) { _, value in
                        guard value.contains("\n") else { return }
                        text.wrappedValue = value.replacingOccurrences(of: "\n", with: "")
                        if field == .phrase { focus = .context } else if model.canAdd { model.add() }
                    }
                if !text.wrappedValue.isEmpty {
                    Button { text.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Tokens.Content.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Loc.t("Очистить", "Clear"))
                }
            }
        }
        .padding(.horizontal, Tokens.Space.s16)
        .padding(.vertical, Tokens.Space.s12)
        .contentShape(Rectangle())
        .onTapGesture { focus = field }
    }
}
