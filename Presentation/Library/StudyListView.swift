//
//  StudyListView.swift
//  EnglishHelper — Presentation
//
//  A list of saved expressions, pushed from the Study dashboard, in one of two scopes:
//  - Caught: everything saved from Say it / Get it / See it, or caught here — "+" generates a card
//    from a phrase or catches cards from photos. Swipe left to delete; swipe right or tap the stack
//    icon to move one into flashcards (a look-alike of a phrase already there asks: merge / move
//    separately), or move them all (optionally leaving the look-alikes); copy every card as text; export.
//  - In flashcards: the expressions being learned — tap one to see the whole card (both sides and
//    its progress; not a practice), swipe left to delete (with their cards); export them to a card
//    file (with progress) or import a card file straight into flashcards; Fix cards; Find duplicates.
//

import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import Domain
import DesignSystem

public struct StudyListView: View {
    @State private var model: StudyListViewModel
    @State private var shareItem: ShareItem?
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showImporter = false
    /// In flashcards: the card opened for a look.
    @State private var previewed: Domain.Expression?
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
        .toolbarTitleDisplayMode(.inlineLarge)   // same title row as the main screens
        .toolbar {
            if model.canTransferCards {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { model.exportCards() } label: {
                            Label(Loc.t("Экспортировать карточки", "Export cards"), systemImage: "square.and.arrow.up")
                        }
                        .disabled(model.expressions.isEmpty)
                        Button { showImporter = true } label: {
                            Label(Loc.t("Импортировать карточки", "Import cards"), systemImage: "square.and.arrow.down")
                        }
                        if model.canFixCards || model.canFindDuplicates {
                            Divider()
                        }
                        if model.canFixCards {
                            Button {
                                if subscription.tier.canUseFlashcards { model.openFix() } else { ui.showPaywall = true }
                            } label: {
                                Label(Loc.t("Исправить карточки", "Fix cards"), systemImage: "wand.and.stars")
                            }
                            .disabled(model.expressions.isEmpty)
                        }
                        if model.canFindDuplicates {
                            Button {
                                if subscription.tier.canUseFlashcards { model.openDuplicates() } else { ui.showPaywall = true }
                            } label: {
                                Label(Loc.t("Найти дубли", "Find duplicates", "Trouver les doublons", "Buscar duplicados",
                                            "Duplikate finden", "Trova duplicati"), systemImage: "square.on.square")
                            }
                            .disabled(model.expressions.count < 2)
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                    .accessibilityLabel(Loc.t("Экспорт и импорт карточек", "Export and import cards"))
                    .accessibilityIdentifier("cards.transfer")
                }
            }
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
        .sheet(item: $model.fixSession, onDismiss: { model.endFix() }) { session in
            FixCardsView(model: session) { model.fixSession = nil }
                .environment(subscription)
        }
        .sheet(item: $model.duplicatesSession, onDismiss: { model.endDuplicates() }) { session in
            DuplicatesView(model: session) { model.duplicatesSession = nil }
                .environment(subscription)
        }
        .confirmationDialog(Loc.t("Похоже, уже есть во флеш-картах", "Looks like it's already in flashcards"),
                            isPresented: lookAlikeBinding, titleVisibility: .visible,
                            presenting: model.lookAlike) { lookAlike in
            Button(Loc.t("Объединить", "Merge", "Fusionner", "Unir", "Zusammenführen", "Unisci")) {
                model.mergeIntoFlashcards(lookAlike)
            }
            Button(Loc.t("Перенести отдельно", "Move separately", "Déplacer séparément", "Mover por separado",
                         "Separat verschieben", "Sposta separatamente")) {
                model.moveSeparately(lookAlike)
            }
            Button(Loc.t("Отмена", "Cancel"), role: .cancel) {}
        } message: { lookAlike in
            let existing = lookAlike.existing.map { "«\($0.en)» — \($0.ru)" }.joined(separator: "\n")
            Text(Loc.t("«\(lookAlike.caught.en)» похоже на:\n\(existing)\n\nОбъединить — модель соберёт одну карточку (несколько значений пронумерует), прогресс изучения сохранится.",
                       "\"\(lookAlike.caught.en)\" looks like:\n\(existing)\n\nMerge — the model makes one card (numbering several meanings), and the learning progress stays."))
        }
        .confirmationDialog(Loc.t("Похоже, это другая фраза", "Looks like another phrase"),
                            isPresented: notADuplicateBinding, titleVisibility: .visible,
                            presenting: model.notADuplicate) { lookAlike in
            Button(Loc.t("Перенести отдельно", "Move separately", "Déplacer séparément", "Mover por separado",
                         "Separat verschieben", "Sposta separatamente")) {
                model.moveSeparately(lookAlike)
            }
            Button(Loc.t("Отмена", "Cancel"), role: .cancel) {}
        } message: { lookAlike in
            Text(Loc.t("Модель не нашла среди похожих карточек ту же фразу, что «\(lookAlike.caught.en)» — объединять не с чем.",
                       "The model found none of the look-alikes to be the same phrase as \"\(lookAlike.caught.en)\" — nothing to merge with."))
        }
        .sheet(item: $previewed) { expression in
            CardPreviewView(expression: expression, cards: model.cards(for: expression),
                            isPlaying: model.isPlaying(expression), onPlay: { model.play(expression) },
                            notDuplicates: model.notDuplicates(of: expression))
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { model.importCards(data) } else { model.reportImportReadFailed() }
        }
        .overlay {
            if model.isImporting || model.isMerging {
                VStack(spacing: Tokens.Space.s12) {
                    ProgressView()
                    Text(model.isMerging ? Loc.t("Объединяю карточки…", "Merging the cards…")
                                         : Loc.t("Импортирую карточки…", "Importing cards…"))
                        .textStyle(Tokens.Text.subhead)
                        .foregroundStyle(Tokens.Content.secondary)
                }
                .padding(Tokens.Space.s24)
                .glassPanel(cornerRadius: Tokens.Radius.card)
            }
        }
        .alert(Loc.t("Импорт карточек", "Card import"), isPresented: importMessageBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.importMessage ?? "")
        }
        // Searches every field of the cards (phrase, translation, example, synonyms, note).
        .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Loc.t("Поиск по карточкам", "Search cards"))
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
            let all = model.expressions.count, alike = model.moveAllLookAlikes.count
            if alike > 0 && alike < all {
                Button(Loc.t("Перенести без похожих (\(all - alike))", "Move all but look-alikes (\(all - alike))",
                             "Déplacer sauf les similaires (\(all - alike))", "Mover salvo las parecidas (\(all - alike))",
                             "Ohne ähnliche verschieben (\(all - alike))", "Sposta tranne le simili (\(all - alike))")) {
                    model.moveAllToFlashcards(skippingLookAlikes: true)
                }
            }
            Button(Loc.t("Перенести (\(all))", "Move (\(all))", "Déplacer (\(all))", "Mover (\(all))",
                         "Verschieben (\(all))", "Sposta (\(all))")) {
                model.moveAllToFlashcards()
            }
            Button(Loc.t("Отмена", "Cancel"), role: .cancel) {}
        } message: {
            let alike = model.moveAllLookAlikes.count
            Text(alike == 0
                 ? Loc.t("Все фразы из «Пойманных» станут флеш-картами, список очистится.",
                         "Every phrase in Caught becomes flashcards, and the list empties.")
                 : Loc.t("Похожи на фразы во флеш-картах: \(alike). Без них они останутся в «Пойманных» — их можно перенести по одной и объединить.",
                         "Look like phrases in flashcards: \(alike). Leave them out, and they stay in Caught — move them one by one to merge."))
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
                           message: Loc.t("Перенесите фразы из «Пойманных» или импортируйте файл карточек.",
                                          "Move phrases from Caught, or import a card file."),
                           actionTitle: model.canTransferCards ? Loc.t("Импортировать карточки", "Import cards") : nil,
                           action: model.canTransferCards ? { showImporter = true } : nil)
            }
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            if model.canMoveToFlashcards && !model.isSearching {
                EHButton(Loc.t("Перенести все во флеш-карты", "Move all to flashcards"),
                         icon: "rectangle.stack.badge.plus", kind: .tonal, fillWidth: true,
                         accessibilityID: "caught.moveAll") { model.prepareMoveAll() }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: Tokens.Space.s4, leading: Tokens.Space.s16,
                                              bottom: Tokens.Space.s8, trailing: Tokens.Space.s16))
            }
            ForEach(model.visibleExpressions) { expression in
                StudyRow(expression: expression,
                         isPlaying: model.isPlaying(expression),
                         onPlay: { model.play(expression) },
                         onExplain: { ui.pendingExplain = ExplainRequest(text: expression.en) },
                         onStudy: model.canMoveToFlashcards ? { model.moveToFlashcards(expression) } : nil,
                         cards: model.cards(for: expression),
                         onOpen: caught ? nil : { previewed = expression })
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
        .overlay {
            if model.isSearching && model.visibleExpressions.isEmpty {
                StatusView(systemImage: "magnifyingglass", title: Loc.t("Ничего не найдено", "No results"),
                           message: Loc.t("Поиск идёт по фразе, переводу, примеру, синонимам и пояснению.",
                                          "Search looks in the phrase, translation, example, synonyms and note."))
            }
        }
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

    private var importMessageBinding: Binding<Bool> {
        Binding(get: { model.importMessage != nil }, set: { if !$0 { model.clearImportMessage() } })
    }

    private var lookAlikeBinding: Binding<Bool> {
        Binding(get: { model.lookAlike != nil }, set: { if !$0 { model.lookAlike = nil } })
    }

    private var notADuplicateBinding: Binding<Bool> {
        Binding(get: { model.notADuplicate != nil }, set: { if !$0 { model.notADuplicate = nil } })
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
    /// In flashcards: tapping the row opens the whole card.
    var onOpen: (() -> Void)?
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
        .modifier(OpenAction(onOpen: onOpen))
    }
}

extension StudyRow {
    @ViewBuilder fileprivate var statusTags: some View {
        ForEach(cards) { CardStatusTag(card: $0) }
    }
}

/// One card's status: which way it asks, how well it's known (the dashboard's stage tone + name) and
/// how many times it has been answered.
/// Tapping the row (outside its icon buttons) — and VoiceOver's activate — opens the card.
private struct OpenAction: ViewModifier {
    let onOpen: (() -> Void)?

    func body(content: Content) -> some View {
        if let onOpen {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default) { onOpen() }
                .accessibilityHint(Loc.t("Показать карточку целиком", "Shows the whole card"))
        } else {
            content
        }
    }
}

struct CardStatusTag: View {
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
