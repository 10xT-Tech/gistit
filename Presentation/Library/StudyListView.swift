//
//  StudyListView.swift
//  EnglishHelper — Presentation
//
//  "Saved for later" — pushed from the Study dashboard. Everything saved from Say it / Get it / See it
//  (or added here) that isn't in flashcards yet: swipe left to delete, swipe right or tap the stack
//  icon to move it into flashcards; add by hand; export every saved expression (.xml / Anki).
//

import SwiftUI
import UIKit
import Domain
import DesignSystem

public struct StudyListView: View {
    @State private var model: StudyListViewModel
    @State private var shareItem: ShareItem?
    @Environment(AppUIState.self) private var ui

    public init(model: StudyListViewModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            ScreenBackground()
            contentSection
        }
        .navigationTitle(Loc.t("Отложенные", "Saved for later"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(StudyListViewModel.ExportFormat.allCases, id: \.self) { format in
                        Button(format.title) { model.export(format) }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(Loc.t("Экспортировать список", "Export list"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.showAddSheet = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(Loc.t("Добавить выражение", "Add expression"))
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $model.showAddSheet) { addSheet }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .onChange(of: model.exportedDeck) { _, deck in
            guard let deck else { return }
            if let url = writeTemp(deck) {
                shareItem = ShareItem(url: url)
                model.clearExport()
            } else {
                model.reportExportWriteFailed()   // don't silently swallow the temp-write failure
            }
        }
        .onChange(of: model.showAddSheet) { _, shown in
            if !shown { model.resetAddForm() }    // clear stale text/error on Cancel or swipe-dismiss
        }
        .alert(Loc.t("Экспорт", "Export"), isPresented: exportErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.exportError ?? "")
        }
        .alert(Loc.t("Список", "List"), isPresented: actionErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    // MARK: Content

    @ViewBuilder private var contentSection: some View {
        switch model.phase {
        case .loading:
            LoadingView(Loc.t("Загружаю…", "Loading…"))
        case .failed:
            StatusView(systemImage: "exclamationmark.triangle", title: Loc.t("Не удалось загрузить", "Couldn't load"),
                       message: model.errorMessage,
                       actionTitle: Loc.t("Повторить", "Retry"), action: { Task { await model.load() } })
        case .empty:
            StatusView(systemImage: "tray", title: Loc.t("Пока пусто", "Nothing yet"),
                       message: Loc.t("Сохраняйте фразы из «Сказать», «Понять» или «Смотреть» — или добавьте вручную.",
                                      "Save phrases from “Say it”, “Get it”, or “See it” — or add them manually."),
                       actionTitle: Loc.t("Добавить", "Add"), action: { model.showAddSheet = true })
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            ForEach(model.expressions) { expression in
                StudyRow(expression: expression,
                         isPlaying: model.isPlaying(expression),
                         onPlay: { model.play(expression) },
                         onExplain: { ui.pendingExplain = ExplainRequest(text: expression.en) },
                         onStudy: model.canMoveToFlashcards ? { model.moveToFlashcards(expression) } : nil)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: Tokens.Space.s4, leading: Tokens.Space.s16,
                                              bottom: Tokens.Space.s4, trailing: Tokens.Space.s16))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { model.delete(expression) } label: {
                            Label(Loc.t("Удалить", "Delete"), systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if model.canMoveToFlashcards {
                            Button { model.moveToFlashcards(expression) } label: {
                                Label(Loc.t("Учить", "Learn"), systemImage: "rectangle.stack.badge.plus")
                            }
                            .tint(Tokens.Signal.success)
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.default, value: model.expressions.map(\.id))
    }

    // MARK: Add sheet

    private var addSheet: some View {
        NavigationStack {
            VerticalScrollView {
                VStack(spacing: Tokens.Space.s16) {
                    if model.needsAPIKey {
                        HStack(spacing: Tokens.Space.s8) {
                            Image(systemName: "key.slash").foregroundStyle(Tokens.Signal.warning)
                            Text(Loc.t("Без ключа Claude API карточка сохранится без перевода и примеров.",
                                       "Without a Claude API key, the card is saved without translation or examples."))
                                .textStyle(Tokens.Text.footnote)
                                .foregroundStyle(Tokens.Content.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GlassField(Loc.t("Английское выражение", "English expression"), text: $model.newEnglish)
                    GlassField(Loc.t("Контекст (необязательно)", "Context (optional)"), text: $model.newContext)

                    if let addError = model.addError {
                        Text(addError)
                            .textStyle(Tokens.Text.footnote)
                            .foregroundStyle(Tokens.Signal.error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if model.isAdding {
                        LoadingView(Loc.t("Дополняю переводом и примерами…", "Adding translation and examples…"))
                    } else {
                        EHButton(Loc.t("Сохранить", "Save"), icon: "sparkles", kind: .primary, fillWidth: true) {
                            model.add()
                        }
                        .disabled(!model.canAdd)   // EHButton dims itself when disabled
                    }
                }
                .padding(Tokens.Space.s20)
            }
            .background(Tokens.Surface.background)
            .navigationTitle(Loc.t("Новое выражение", "New expression"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(Loc.t("Отмена", "Cancel")) { model.showAddSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Helpers

    private var exportErrorBinding: Binding<Bool> {
        Binding(get: { model.exportError != nil }, set: { if !$0 { model.clearExportError() } })
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.clearActionError() } })
    }

    private func writeTemp(_ deck: ExportedDeck) -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: deck.filename)
        do {
            try deck.data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

private struct StudyRow: View {
    let expression: Domain.Expression
    let isPlaying: Bool
    let onPlay: () -> Void
    let onExplain: () -> Void
    /// Move into flashcards; nil hides the action (flashcards not wired).
    let onStudy: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s12) {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                Text(expression.en)
                    .textStyle(Tokens.Text.headline)
                    .foregroundStyle(Tokens.Content.primary)
                if !expression.ru.isEmpty {
                    Text(expression.ru)
                        .textStyle(Tokens.Text.subhead)
                        .foregroundStyle(Tokens.Content.secondary)
                }
                if !expression.synonyms.isEmpty {
                    Text(expression.synonyms.joined(separator: " · "))
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Content.tertiary)
                }
            }
            Spacer(minLength: Tokens.Space.s8)
            VStack(alignment: .trailing, spacing: Tokens.Space.s12) {
                // Play · Explain · Copy · Share in one icon row — same order/look as the result cards.
                HStack(spacing: Tokens.Space.s16) {
                    Button(action: onPlay) {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .symbolEffect(.variableColor.iterative, isActive: isPlaying && !reduceMotion)
                            .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                            .foregroundStyle(isPlaying ? Tokens.Content.primary : Tokens.Content.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Loc.t("Озвучить", "Play"))

                    Button(action: onExplain) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                            .foregroundStyle(Tokens.Content.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Loc.t("Объяснить", "Explain"))

                    CopyButton(expression.en, style: .icon,
                               accessibilityLabel: Loc.t("Скопировать выражение", "Copy expression"))
                    ShareButton(expression.en, style: .icon,
                                accessibilityLabel: Loc.t("Поделиться выражением", "Share expression"))
                }
                if let onStudy {
                    // The swipe-right action, as a visible button.
                    Button(action: onStudy) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                            .foregroundStyle(Tokens.Content.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Loc.t("Учить во флеш-картах", "Study in flashcards"))
                    .accessibilityIdentifier("saved.study")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(expression.en). \(expression.ru)")
        .accessibilityAction(named: Loc.t("Озвучить", "Play")) { onPlay() }
        .accessibilityAction(named: Loc.t("Объяснить", "Explain")) { onExplain() }
        .accessibilityAction(named: Loc.t("Скопировать", "Copy")) {
            UIPasteboard.general.string = expression.en
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        .accessibilityAction(named: Loc.t("Поделиться", "Share")) { ShareSheetPresenter.share(expression.en) }
        .modifier(StudyAction(onStudy: onStudy))
    }
}

/// VoiceOver: "Study in flashcards" as an action on the combined row (when offered).
private struct StudyAction: ViewModifier {
    let onStudy: (() -> Void)?

    func body(content: Content) -> some View {
        if let onStudy {
            content.accessibilityAction(named: Loc.t("Учить во флеш-картах", "Study in flashcards")) { onStudy() }
        } else {
            content
        }
    }
}
