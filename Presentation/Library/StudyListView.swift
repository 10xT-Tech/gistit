//
//  StudyListView.swift
//  EnglishHelper — Presentation
//
//  "Изучаю" — flat study list: add (enrich-then-store), swipe-delete, toggle learned, clean up
//  learned (confirmed bulk delete), export .xml.
//

import SwiftUI
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
        NavigationStack {
            ZStack {
                ScreenBackground()
                contentSection
            }
            .navigationTitle(Loc.t("Изучаю", "Study"))
            .settingsTrigger()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(StudyListViewModel.ExportFormat.allCases, id: \.self) { format in
                            Button(format.title) { model.export(format) }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(model.expressions.isEmpty)
                    .accessibilityLabel(Loc.t("Экспортировать список", "Export list"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Clean up: drop every card marked learned — behind a confirmation (no undo).
                    Button { model.showCleanUpConfirmation = true } label: { Image(systemName: "eraser") }
                        .disabled(model.learnedCount == 0)
                        .accessibilityLabel(Loc.t("Убрать изученные", "Clean up learned"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showAddSheet = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(Loc.t("Добавить выражение", "Add expression"))
                }
            }
            .confirmationDialog(
                Loc.t("Убрать изученные карточки?", "Remove learned cards?"),
                isPresented: $model.showCleanUpConfirmation,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) { model.cleanUpLearned() } label: {
                    Text(Loc.t("Удалить изученные (\(model.learnedCount))",
                               "Delete learned (\(model.learnedCount))"))
                }
                Button(Loc.t("Отмена", "Cancel"), role: .cancel) {}
            } message: {
                Text(Loc.t("Карточки, отмеченные как изученные, будут удалены из списка. Это нельзя отменить.",
                           "Cards marked as learned will be removed from the list. This can't be undone."))
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
            StatusView(systemImage: "rectangle.stack", title: Loc.t("Пока пусто", "Nothing yet"),
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
                         onExplain: { ui.pendingExplain = ExplainRequest(text: expression.en) })
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
                        Button { model.toggleLearned(expression) } label: {
                            Label(expression.learned ? Loc.t("Не выучено", "Not learned") : Loc.t("Выучено", "Learned"),
                                  systemImage: expression.learned ? "arrow.uturn.left" : "checkmark")
                        }
                        .tint(Tokens.Signal.success)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s12) {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                Text(expression.en)
                    .textStyle(Tokens.Text.headline)
                    .foregroundStyle(Tokens.Content.primary)
                    .strikethrough(expression.learned, color: Tokens.Content.tertiary)
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
            VStack(alignment: .trailing, spacing: Tokens.Space.s8) {
                // Play · Explain in one icon row — same order/look as the result cards.
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
                }
                if expression.learned {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Tokens.Signal.success)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(expression.en). \(expression.ru). \(expression.learned ? Loc.t("Выучено", "Learned") : Loc.t("Не выучено", "Not learned"))")
        .accessibilityAction(named: Loc.t("Озвучить", "Play")) { onPlay() }
        .accessibilityAction(named: Loc.t("Объяснить", "Explain")) { onExplain() }
    }
}
