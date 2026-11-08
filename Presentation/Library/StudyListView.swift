//
//  StudyListView.swift
//  EnglishHelper — Presentation
//
//  A list of saved expressions, pushed from the Study dashboard, in one of two scopes:
//  - Caught: everything saved from Say it / Get it / See it, or caught here — "+" generates a card
//    from a phrase or catches cards from photos. Swipe left to delete; swipe right or tap the stack
//    icon to move one into flashcards, or move them all; copy every card as text; export.
//  - In flashcards: the expressions being learned — swipe left to delete (with their cards).
//

import SwiftUI
import UIKit
import PhotosUI
import Domain
import DesignSystem

public struct StudyListView: View {
    @State private var model: StudyListViewModel
    @State private var shareItem: ShareItem?
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @Environment(AppUIState.self) private var ui
    @Environment(SubscriptionState.self) private var subscription

    /// Photos per batch — one model request each.
    private static let maxPhotos = 10

    public init(model: StudyListViewModel) {
        self.model = model
    }

    private var caught: Bool { model.scope == .caught }

    public var body: some View {
        ZStack {
            ScreenBackground()
            contentSection
        }
        .navigationTitle(caught ? Loc.t("Пойманные", "Caught") : Loc.t("Во флеш-картах", "In flashcards"))
        .toolbar {
            if caught {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(StudyListViewModel.ExportFormat.allCases, id: \.self) { format in
                            Button(format.title) { model.export(format) }
                        }
                        Button {
                            UIPasteboard.general.string = model.allCardsText
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } label: {
                            Label(Loc.t("Скопировать все карточки", "Copy all cards"), systemImage: "doc.on.doc")
                        }
                        .disabled(model.expressions.isEmpty)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(Loc.t("Экспортировать список", "Export list"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { model.showAddSheet = true } label: {
                            Label(Loc.t("Сгенерировать по фразе", "Generate from a phrase"), systemImage: "sparkles")
                        }
                        if model.canCatchFromPhotos {
                            Button { showPhotoPicker = true } label: {
                                Label(Loc.t("Распознать с фото", "From photos"), systemImage: "photo.on.rectangle")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Loc.t("Добавить карточку", "Add a card"))
                    .accessibilityIdentifier("caught.add")
                }
            }
        }
        .task {
            await model.load()
            #if DEBUG
            // XCUI can't drive the system photo picker: `-uiTestCatchPhotos` catches from two blank images.
            if caught, ProcessInfo.processInfo.arguments.contains("-uiTestCatchPhotos"), model.catchSession == nil {
                let blank = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { _ in }
                model.startCatch(photoCount: 2)?.run([blank, blank])
            }
            #endif
        }
        .sheet(isPresented: $model.showAddSheet) { addSheet }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: Self.maxPhotos, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            catchCards(from: items)
        }
        .sheet(item: $model.catchSession, onDismiss: { model.endCatch() }) { session in
            CatchFromPhotosView(model: session) { model.catchSession = nil }
                .environment(subscription)
        }
        .confirmationDialog(
            Loc.t("Перенести все во флеш-карты?", "Move all to flashcards?"),
            isPresented: $model.showMoveAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(Loc.t("Перенести (\(model.expressions.count))", "Move (\(model.expressions.count))",
                         "Déplacer (\(model.expressions.count))", "Mover (\(model.expressions.count))",
                         "Verschieben (\(model.expressions.count))", "Sposta (\(model.expressions.count))")) {
                model.moveAllToFlashcards()
            }
            Button(Loc.t("Отмена", "Cancel"), role: .cancel) {}
        } message: {
            Text(Loc.t("Все фразы из «Пойманных» станут флеш-картами, список очистится.",
                       "Every phrase in Caught becomes flashcards, and the list empties."))
        }
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

    /// Open the progress sheet at once, then load + downscale the picked photos and start.
    private func catchCards(from items: [PhotosPickerItem]) {
        guard let session = model.startCatch(photoCount: items.count) else { return }
        Task {
            var photos: [Data?] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    photos.append(await ImagePreparation.prepare(data))
                } else {
                    photos.append(nil)
                }
            }
            session.run(photos)
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
            if caught {
                StatusView(systemImage: "tray", title: Loc.t("Пока пусто", "Nothing yet"),
                           message: Loc.t("Сохраняйте фразы из «Сказать», «Понять» или «Смотреть», генерируйте карточки по фразе или распознавайте с фото.",
                                          "Save phrases from “Say it”, “Get it”, or “See it”, generate a card from a phrase, or catch cards from photos."),
                           actionTitle: Loc.t("Добавить", "Add"), action: { model.showAddSheet = true })
            } else {
                StatusView(systemImage: "rectangle.stack", title: Loc.t("Пока пусто", "Nothing yet"),
                           message: Loc.t("Перенесите фразы из «Пойманных», чтобы учить их во флеш-картах.",
                                          "Move phrases from Caught to learn them as flashcards."))
            }
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            if model.canMoveToFlashcards {
                EHButton(Loc.t("Перенести все во флеш-карты", "Move all to flashcards"),
                         icon: "rectangle.stack.badge.plus", kind: .tonal, fillWidth: true,
                         accessibilityID: "caught.moveAll") { model.showMoveAllConfirmation = true }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: Tokens.Space.s4, leading: Tokens.Space.s16,
                                              bottom: Tokens.Space.s8, trailing: Tokens.Space.s16))
            }
            ForEach(model.expressions) { expression in
                StudyRow(expression: expression,
                         isPlaying: model.isPlaying(expression),
                         onPlay: { model.play(expression) },
                         onExplain: { ui.pendingExplain = ExplainRequest(text: expression.en) },
                         onStudy: model.canMoveToFlashcards ? { model.moveToFlashcards(expression) } : nil,
                         cards: model.cards(for: expression))
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
                    GlassField(Loc.t("Фраза на изучаемом языке", "A phrase in the language you're learning"),
                               text: $model.newEnglish)
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
                        EHButton(Loc.t("Сгенерировать карточку", "Generate the card"), icon: "sparkles", kind: .primary,
                                 fillWidth: true) {
                            model.add()
                        }
                        .disabled(!model.canAdd)   // EHButton dims itself when disabled
                    }
                }
                .padding(Tokens.Space.s20)
            }
            .background(Tokens.Surface.background)
            .navigationTitle(Loc.t("Новая карточка", "New card"))
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
    /// In flashcards: the expression's cards — shown as status tags (stage + reviews).
    var cards: [ReviewCard] = []
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
                if !cards.isEmpty {
                    // Two tags side by side; stacked when they don't fit (narrow width, large text).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Tokens.Space.s8) { statusTags }
                        VStack(alignment: .leading, spacing: Tokens.Space.s4) { statusTags }
                    }
                    .padding(.top, Tokens.Space.s4)
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

                    // The whole card as four lines (expression, translation, example, synonyms).
                    CopyButton(expression.cardText, style: .icon,
                               accessibilityLabel: Loc.t("Скопировать карточку", "Copy card"))
                    ShareButton(expression.cardText, style: .icon,
                                accessibilityLabel: Loc.t("Поделиться карточкой", "Share card"))
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
        .accessibilityLabel(([expression.en, expression.ru] + cards.map(CardStatusTag.spoken)).joined(separator: ". "))
        .accessibilityAction(named: Loc.t("Озвучить", "Play")) { onPlay() }
        .accessibilityAction(named: Loc.t("Объяснить", "Explain")) { onExplain() }
        .accessibilityAction(named: Loc.t("Скопировать", "Copy")) {
            UIPasteboard.general.string = expression.cardText
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        .accessibilityAction(named: Loc.t("Поделиться", "Share")) { ShareSheetPresenter.share(expression.cardText) }
        .modifier(StudyAction(onStudy: onStudy))
    }
}

extension StudyRow {
    @ViewBuilder fileprivate var statusTags: some View {
        ForEach(cards) { CardStatusTag(card: $0) }
    }
}

/// One card's status: which way it asks, how well it's known (the dashboard's stage tone + name) and
/// how many times it has been answered.
private struct CardStatusTag: View {
    let card: ReviewCard

    var body: some View {
        HStack(spacing: Tokens.Space.s4) {
            Circle()
                .fill(Tokens.Chart.stage[card.stage.rawValue])
                .frame(width: 8, height: 8)
            Text("\(Self.direction(card.direction)): \(Self.stage(card.stage))")
            Image(systemName: "arrow.counterclockwise")
                .imageScale(.small)
            Text("\(card.reps)")
                .monospacedDigit()
        }
        .textStyle(Tokens.Text.caption)
        .foregroundStyle(Tokens.Content.secondary)
        .padding(.horizontal, Tokens.Space.s8)
        .padding(.vertical, 3)
        .background(Tokens.Fill.subtle, in: Capsule())
        .fixedSize()
    }

    static func direction(_ direction: CardDirection) -> String {
        switch direction {
        case .recognition: Loc.t("Узнать", "Recognize", "Reconnaître", "Reconocer", "Erkennen", "Riconoscere")
        case .recall: Loc.t("Вспомнить", "Recall", "Retrouver", "Recordar", "Abrufen", "Ricordare")
        }
    }

    static func stage(_ stage: CardStage) -> String {
        switch stage {
        case .new: Loc.t("новая", "new", "nouvelle", "nueva", "neu", "nuova")
        case .learning: Loc.t("изучается", "learning", "en apprentissage", "aprendiendo", "im Lernen", "in apprendimento")
        case .young: Loc.t("молодая", "young", "jeune", "joven", "jung", "giovane")
        case .mature: Loc.t("зрелая", "mature", "mature", "madura", "gefestigt", "matura")
        }
    }

    /// VoiceOver: "Recognize: young, reviews: 4".
    static func spoken(_ card: ReviewCard) -> String {
        let reviews = Loc.t("повторений: \(card.reps)", "reviews: \(card.reps)", "révisions : \(card.reps)",
                            "repasos: \(card.reps)", "Wiederholungen: \(card.reps)", "ripassi: \(card.reps)")
        return "\(direction(card.direction)): \(stage(card.stage)), \(reviews)"
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
