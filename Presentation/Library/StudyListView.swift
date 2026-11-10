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
                                // Fix cards calls the model: Pro.
                                if subscription.tier.canUseModelCardTools { model.openFix() } else { ui.showPaywall = true }
                            } label: {
                                Label(Loc.t("Исправить карточки", "Fix cards"),
                                      systemImage: subscription.tier.canUseModelCardTools ? "wand.and.stars" : "lock.fill")
                            }
                            .disabled(model.expressions.isEmpty)
                        }
                        if model.canFindDuplicates {
                            Button {
                                model.openDuplicates()             // the search is on the device; Check (the model) is Pro
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
                        Divider()
                        Button(role: .destructive) { model.showDeleteAllConfirmation = true } label: {
                            Label(Loc.t("Удалить все", "Delete all", "Tout supprimer", "Eliminar todas",
                                        "Alle löschen", "Elimina tutte"), systemImage: "trash")
                        }
                        .disabled(model.expressions.isEmpty)
                        .accessibilityIdentifier("caught.deleteAll")
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
        .sheet(item: $model.lookAlike) { lookAlike in
            ConfirmSheet(icon: "square.on.square",
                         title: Loc.t("Похоже, уже есть во флеш-картах", "Looks like it's already in flashcards"),
                         message: Loc.t("«\(lookAlike.caught.en)» похоже на эти карточки. «Объединить» — модель соберёт одну карточку (несколько значений пронумерует), прогресс изучения сохранится.",
                                        "\"\(lookAlike.caught.en)\" looks like these cards. Merge — the model makes one card (numbering several meanings), and the learning progress stays."),
                         actions: [
                             ConfirmAction(Loc.t("Объединить", "Merge", "Fusionner", "Unir", "Zusammenführen", "Unisci"),
                                           icon: "arrow.triangle.merge") { model.mergeIntoFlashcards(lookAlike) },
                             ConfirmAction(Loc.t("Перенести отдельно", "Move separately", "Déplacer séparément",
                                                 "Mover por separado", "Separat verschieben", "Sposta separatamente"),
                                           role: .secondary) { model.moveSeparately(lookAlike) },
                         ]) {
                PhraseList(phrases: lookAlike.existing.map { ($0.en, $0.ru) })
            }
        }
        .sheet(item: $model.notADuplicate) { lookAlike in
            ConfirmSheet(icon: "questionmark.square.dashed",
                         title: Loc.t("Похоже, это другая фраза", "Looks like another phrase"),
                         message: Loc.t("Модель не нашла среди похожих карточек ту же фразу, что «\(lookAlike.caught.en)» — объединять не с чем.",
                                        "The model found none of the look-alikes to be the same phrase as \"\(lookAlike.caught.en)\" — nothing to merge with."),
                         actions: [
                             ConfirmAction(Loc.t("Перенести отдельно", "Move separately", "Déplacer séparément",
                                                 "Mover por separado", "Separat verschieben", "Sposta separatamente"),
                                           icon: "rectangle.stack.badge.plus") { model.moveSeparately(lookAlike) },
                         ])
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
            if model.isImporting || model.isMerging || model.isCheckingLookAlikes {
                VStack(spacing: Tokens.Space.s12) {
                    ProgressView()
                    Text(model.isMerging ? Loc.t("Объединяю карточки…", "Merging the cards…")
                         : model.isCheckingLookAlikes ? Loc.t("Ищу похожие во флеш-картах…", "Looking for look-alikes in flashcards…")
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
        .sheet(isPresented: $model.showAddSheet) { NewCardSheet(model: model) }
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
        .sheet(isPresented: $model.showDeleteAllConfirmation) {
            let all = model.expressions.count
            ConfirmSheet(icon: "trash",
                         title: Loc.t("Удалить все из «Пойманных»?", "Delete everything in Caught?",
                                      "Tout supprimer dans « Capturées » ?", "¿Eliminar todo en «Atrapadas»?",
                                      "Alles in „Eingefangen“ löschen?", "Eliminare tutto in «Catturate»?"),
                         message: Loc.t("Фраз: \(all). Их нельзя будет вернуть. Флеш-карты не затронутся.",
                                        "Phrases: \(all). They can't be brought back. Your flashcards aren't touched."),
                         actions: [ConfirmAction(Loc.t("Удалить (\(all))", "Delete (\(all))", "Supprimer (\(all))",
                                                       "Eliminar (\(all))", "Löschen (\(all))", "Elimina (\(all))"),
                                                 role: .destructive, accessibilityID: "caught.deleteAll.confirm") {
                             model.deleteAll()
                         }])
        }
        .sheet(isPresented: $model.showMoveAllConfirmation) {
            let all = model.expressions.count, alike = model.moveAllLookAlikes.count
            ConfirmSheet(icon: "rectangle.stack.badge.plus",
                         title: Loc.t("Перенести все во флеш-карты?", "Move all to flashcards?"),
                         message: alike == 0
                            ? Loc.t("Все фразы из «Пойманных» станут флеш-картами, список очистится.",
                                    "Every phrase in Caught becomes flashcards, and the list empties.")
                            : Loc.t("Похожи на фразы во флеш-картах: \(alike). Без них они останутся в «Пойманных» — их можно перенести по одной и объединить.",
                                    "Look like phrases in flashcards: \(alike). Leave them out, and they stay in Caught — move them one by one to merge."),
                         actions: (alike > 0 && alike < all ? [
                             ConfirmAction(Loc.t("Перенести без похожих (\(all - alike))", "Move all but look-alikes (\(all - alike))",
                                                 "Déplacer sauf les similaires (\(all - alike))", "Mover salvo las parecidas (\(all - alike))",
                                                 "Ohne ähnliche verschieben (\(all - alike))", "Sposta tranne le simili (\(all - alike))")) {
                                 model.moveAllToFlashcards(skippingLookAlikes: true)
                             },
                         ] : []) + [
                             ConfirmAction(Loc.t("Перенести (\(all))", "Move (\(all))", "Déplacer (\(all))", "Mover (\(all))",
                                                 "Verschieben (\(all))", "Sposta (\(all))"),
                                           role: alike > 0 && alike < all ? .secondary : .primary) {
                                 model.moveAllToFlashcards()
                             },
                         ])
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
        if model.phase == .loaded {
            list
        } else {
            // Loading / empty / failed sit in a scroll view too, filling it: with no scroll view under it,
            // the navigation bar's large title and search field stayed on screen over Study for a moment
            // when going back from an empty list.
            ScrollView {
                stateSection.containerRelativeFrame([.horizontal, .vertical])
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder private var stateSection: some View {
        switch model.phase {
        case .loading:
            LoadingView(Loc.t("Загружаю…", "Loading…"))
        case .failed:
            StatusView(systemImage: "exclamationmark.triangle", title: Loc.t("Не удалось загрузить", "Couldn't load"),
                       message: model.errorMessage,
                       actionTitle: Loc.t("Повторить", "Retry"), action: { Task { await model.load() } })
        case .empty:
            if caught {
                // Both ways to add a card, side by side — as the "+" menu offers them.
                VStack(spacing: Tokens.Space.s8) {
                    StatusView(systemImage: "tray", title: Loc.t("Пока пусто", "Nothing yet"),
                               message: Loc.t("Сохраняйте фразы из «Сказать», «Понять» или «Смотреть» — или добавьте карточки сами:",
                                              "Save phrases from “Say it”, “Get it”, or “See it” — or add cards yourself:"))
                    VStack(spacing: Tokens.Space.s8) {
                        if model.canCatchFromPhotos {
                            EHButton(Loc.t("Распознать с фото", "From photos"), icon: "photo.on.rectangle", kind: .primary,
                                     fillWidth: true, accessibilityID: "caught.empty.photos") { showPhotoPicker = true }
                        }
                        EHButton(Loc.t("Сгенерировать по фразе", "Generate from a phrase"), icon: "sparkles",
                                 kind: model.canCatchFromPhotos ? .tonal : .primary, fillWidth: true,
                                 accessibilityID: "caught.empty.phrase") { model.showAddSheet = true }
                    }
                    .padding(.horizontal, Tokens.Space.s24)
                }
            } else {
                StatusView(systemImage: "rectangle.stack", title: Loc.t("Пока пусто", "Nothing yet"),
                           message: Loc.t("Перенесите фразы из «Пойманных» или импортируйте файл карточек.",
                                          "Move phrases from Caught, or import a card file."),
                           actionTitle: model.canTransferCards ? Loc.t("Импортировать карточки", "Import cards") : nil,
                           action: model.canTransferCards ? { showImporter = true } : nil)
            }
        case .loaded:
            EmptyView()
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

    // MARK: Helpers

    private var exportErrorBinding: Binding<Bool> {
        Binding(get: { model.exportError != nil }, set: { if !$0 { model.clearExportError() } })
    }

    private var importMessageBinding: Binding<Bool> {
        Binding(get: { model.importMessage != nil }, set: { if !$0 { model.clearImportMessage() } })
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

/// "«phrase» — translation" lines on a quiet panel (the look-alike sheet's cards).
private struct PhraseList: View {
    let phrases: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            ForEach(Array(phrases.enumerated()), id: \.offset) { _, phrase in
                VStack(alignment: .leading, spacing: 2) {
                    Text(phrase.0)
                        .textStyle(Tokens.Text.headline)
                        .foregroundStyle(Tokens.Content.primary)
                    Text(phrase.1)
                        .textStyle(Tokens.Text.subhead)
                        .foregroundStyle(Tokens.Content.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s12)
        .background(Tokens.Fill.subtle, in: RoundedRectangle(cornerRadius: Tokens.Radius.card / 2))
    }
}
