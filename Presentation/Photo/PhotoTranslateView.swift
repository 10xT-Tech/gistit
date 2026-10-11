//
//  PhotoTranslateView.swift
//  EnglishHelper — Presentation
//
//  "Фото-перевод". Pick from camera/library → OCR boxes over the photo → Russian translation on a
//  SOLID scrim (no glass under text, for AA contrast) → play source / save.
//

import SwiftUI
import UIKit
import PhotosUI
import Domain
import DesignSystem

public struct PhotoTranslateView: View {
    @State private var model: PhotoTranslateViewModel
    @State private var libraryItem: PhotosPickerItem?
    @Environment(AppUIState.self) private var ui

    public init(model: PhotoTranslateViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                VerticalScrollView {
                    VStack(spacing: Tokens.Space.s20) {
                        if model.needsAPIKey { apiKeyBanner }
                        modeSelector
                        contentSection
                    }
                    .padding(Tokens.Space.s20)
                }
            }
            // Screen title matches the tab name ("See it" / "Смотреть") in every language.
            .navigationTitle(Loc.t("Смотреть", "See it"))
            .settingsTrigger()
            .sheet(isPresented: $model.showCameraPriming) { primingSheet }
            .fullScreenCover(isPresented: $model.presentCamera) {
                CameraPicker(onImage: { data in
                                 // Downscale/encode OFF the main actor, then hand back to the @MainActor VM.
                                 Task { model.didCapture(await Self.prepareDetached(data) ?? data) }
                             },
                             onCancel: { model.cameraCancelled() })
                    .ignoresSafeArea()
            }
            .onChange(of: libraryItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let prepared = await Self.prepareDetached(data) {
                        model.didPickFromLibrary(prepared)
                    } else {
                        model.imageLoadFailed()
                    }
                    libraryItem = nil
                }
            }
            .alert(Loc.t("Сохранение", "Saving"), isPresented: saveErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.saveError ?? "")
            }
        }
    }

    /// Surface a background save failure regardless of `phase` (inline error UI is only in `.failed`).
    private var saveErrorBinding: Binding<Bool> {
        Binding(get: { model.saveError != nil }, set: { if !$0 { model.clearSaveError() } })
    }

    @ViewBuilder private var contentSection: some View {
        switch model.phase {
        case .idle:
            idleSection
        case .processing:
            processingSection
        case .result:
            resultSection
        case .failed:
            // No extra top padding: StatusView pads s24 internally; with the source buttons below,
            // a second s24 pushed them under the tab bar. See VoiceView for the same fix.
            VStack(spacing: Tokens.Space.s16) {
                // Keep the photo on screen so it's clearly NOT lost — Retry re-runs this same image.
                if let image = uiImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(image.size.width / image.size.height, contentMode: .fit)
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
                }
                if model.needsSubscription {
                    StatusView(
                        systemImage: "lock",
                        title: Loc.t("Лимит бесплатного плана", "Free plan limit"),
                        message: model.errorMessage,
                        actionTitle: Loc.t("Оформить подписку", "Subscribe"),
                        action: { ui.showPaywall = true }
                    )
                } else {
                    StatusView(
                        systemImage: model.isOffline ? "wifi.slash" : "exclamationmark.triangle",
                        title: model.isOffline ? Loc.t("Нет соединения", "No connection") : Loc.t("Не получилось", "Something went wrong"),
                        message: model.errorMessage,
                        actionTitle: model.canRetry ? Loc.t("Повторить", "Retry") : nil,
                        action: model.canRetry ? { model.retry() } : nil
                    )
                }
                sourceButtons
            }
        }
    }

    // MARK: Sections

    private var modeSelector: some View {
        SegmentedSelector(
            PhotoTranslateViewModel.Mode.allCases,
            selected: model.mode,
            label: { $0.title },
            accessibilityID: "seeit.mode",
            onSelect: { model.selectMode($0) }
        )
        // `.contain` keeps each segment's OWN label (a bare container label would overwrite
        // every segment as "Mode", leaving VoiceOver users unable to tell the options apart).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Loc.t("Режим", "Mode"))
    }

    private var idleSection: some View {
        // Buttons FIRST, hint below: the source buttons stay pinned to the top (aligned with the
        // input controls on the Say it / Get it screens), and the hint fills the space under them.
        VStack(spacing: Tokens.Space.s20) {
            sourceButtons
            if model.mode == .explain {
                StatusView(
                    systemImage: "sparkle.magnifyingglass",
                    title: Loc.t("Что это? Расскажу", "What is it? I'll explain",
                                 "Qu'est-ce que c'est ? Je vous explique", "¿Qué es? Te lo explico",
                                 "Was ist das? Ich erkläre es", "Cos'è? Te lo spiego"),
                    message: Loc.t(
                        "Снимите место, вывеску, знак или предмет — объясню, что это, и расскажу про местные особенности и контекст.",
                        "Snap a place, sign, or object — I'll explain what it is and its local context and quirks.",
                        "Photographiez un lieu, un panneau ou un objet — j'expliquerai ce que c'est, son contexte local et ses particularités.",
                        "Fotografía un lugar, cartel u objeto — te explicaré qué es, su contexto local y sus particularidades.",
                        "Fotografiere einen Ort, ein Schild oder ein Objekt – ich erkläre, was es ist, den lokalen Kontext und Besonderheiten.",
                        "Fotografa un luogo, un cartello o un oggetto: spiegherò cos'è, il contesto locale e le sue particolarità.")
                )
            } else {
                StatusView(
                    systemImage: "camera.viewfinder",
                    title: Loc.t("Переведите текст с фото", "Translate text from a photo",
                                 "Traduire le texte d'une photo", "Traducir texto de una foto",
                                 "Text aus einem Foto übersetzen", "Traduci il testo da una foto"),
                    message: Loc.t(
                        "Снимите вывеску, меню или страницу — распознаю текст и покажу его на изучаемом языке с переводом.",
                        "Snap a sign, menu, or page — I'll read the text and show it in the language you're learning, with a translation.",
                        "Photographiez un panneau, un menu ou une page — je lirai le texte et l'afficherai dans la langue que vous apprenez, avec une traduction.",
                        "Fotografía un cartel, un menú o una página — leeré el texto y lo mostraré en el idioma que estás aprendiendo, con una traducción.",
                        "Fotografiere ein Schild, eine Speisekarte oder eine Seite – ich erkenne den Text und zeige ihn in der Sprache, die du lernst, mit einer Übersetzung.",
                        "Fotografa un cartello, un menu o una pagina: riconoscerò il testo e lo mostrerò nella lingua che stai imparando, con una traduzione.")
                )
            }
        }
    }

    private var sourceButtons: some View {
        VStack(spacing: Tokens.Space.s12) {
            if CameraPicker.isAvailable {
                EHButton(Loc.t("Снять фото", "Take a photo"), icon: "camera", kind: .primary, fillWidth: true) {
                    model.cameraTapped()
                }
            }
            PhotosPicker(selection: $libraryItem, matching: .images) {
                LibraryButtonLabel()
            }
            .accessibilityLabel(Loc.t("Выбрать фото из галереи", "Choose a photo from the library"))
        }
    }

    private var processingSection: some View {
        VStack(spacing: Tokens.Space.s16) {
            if let image = uiImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(image.size.width / image.size.height, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
                    .overlay {
                        ZStack {
                            Tokens.Scrim.solid
                            // A moving bar (not just a spinner) — recognizing + translating a dense
                            // photo can take ~30s, so show visible forward progress while it works.
                            TimedProgressView(progressCaption, expectedDuration: 30)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
                    }
            } else {
                TimedProgressView(progressCaption, expectedDuration: 30)
            }
        }
    }

    private var progressCaption: String {
        model.mode == .explain
            ? Loc.t("Рассматриваю фото…", "Looking at the photo…",
                    "J'observe la photo…", "Observando la foto…",
                    "Betrachte das Foto…", "Osservo la foto…")
            : Loc.t("Распознаю и перевожу…", "Reading and translating…",
                    "Lecture et traduction…", "Leyendo y traduciendo…",
                    "Lese und übersetze…", "Lettura e traduzione…")
    }

    private var resultSection: some View {
        VStack(spacing: Tokens.Space.s16) {
            if let image = uiImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(image.size.width / image.size.height, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            }
            // Translate mode → per-block cards; Explain mode → the scene explanation card.
            // Selected by MODE, not by which result exists: BOTH can be cached for this photo
            // (the view model keeps each mode's result so switches don't re-run the request).
            if model.mode == .translate {
                ForEach(model.blocks) { block in
                    blockCard(block)
                }
            } else if let explanation = model.explanation {
                explanationCard(explanation)
            }
            // Take or pick a NEW photo directly from the result (replaces the current one).
            sourceButtons
        }
    }

    /// Explain mode: what the photo shows + its local/cultural context (read-only, copyable).
    private func explanationCard(_ explanation: SceneExplanation) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            // Mode tag (left) + copy (right) on their own row above the scene title, which sits
            // full-width below — same layout as the Get it / See it Translate cards.
            HStack(spacing: Tokens.Space.s16) {
                CardTagView(Loc.t("Объяснение", "Explanation", "Explication", "Explicación", "Erklärung", "Spiegazione"))
                Spacer(minLength: Tokens.Space.s8)
                CopyButton(explanation.title + "\n\n" + explanation.details, style: .icon,
                           accessibilityLabel: Loc.t("Скопировать объяснение", "Copy explanation"))
            }

            Text(explanation.title)
                .textStyle(Tokens.Text.headline)
                .foregroundStyle(Tokens.Content.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(Tokens.Hairline.default).frame(height: Tokens.Hairline.width)

            Text(explanation.details)
                .textStyle(Tokens.Text.body)
                .foregroundStyle(Tokens.Content.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    /// One recognized block: English + Russian translation, with the full action row.
    private func blockCard(_ block: TranslatedBlock) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            // Mode tag (left) + action icons (right) on their own row above the studied text, which
            // sits full-width below — same layout as the Get it cards (so icons never squeeze the text).
            HStack(spacing: Tokens.Space.s16) {
                CardTagView(Loc.t("Перевод", "Translation", "Traduction", "Traducción", "Übersetzung", "Traduzione"))
                Spacer(minLength: Tokens.Space.s8)
                Button { model.play(block) } label: {
                    Image(systemName: model.isPlaying(block) ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                        .symbolEffect(.variableColor.iterative, isActive: model.isPlaying(block))
                        .foregroundStyle(model.isPlaying(block) ? Tokens.Content.primary : Tokens.Content.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Loc.t("Озвучить", "Play"))

                // Explain ONLY this card's phrase, in its own right — NOT in the photo's context. The
                // photo is just where the phrase was found; the explanation should generalise (what the
                // expression means broadly), so we deliberately do NOT carry the image along.
                Button { ui.pendingExplain = ExplainRequest(text: block.en) } label: {
                    Image(systemName: "lightbulb")
                        .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                        .foregroundStyle(Tokens.Content.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Loc.t("Объяснить", "Explain"))

                CopyButton(block.en, style: .icon,
                           accessibilityLabel: Loc.t("Скопировать выражение", "Copy expression"))

                Button { model.toggleSave(block) } label: {
                    Image(systemName: model.isSaved(block) ? "bookmark.fill" : "bookmark")
                        .font(.system(size: Tokens.Icon.cardActionProminent, weight: .medium))
                        .foregroundStyle(model.isSaved(block) ? Tokens.Content.primary : Tokens.Content.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isSaved(block)
                    ? Loc.t("Убрать из изучаемого", "Remove from study list")
                    : Loc.t("Сохранить в изучаемое", "Save to study list"))
            }

            Text(block.en)
                .textStyle(Tokens.Text.headline)
                .foregroundStyle(Tokens.Content.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(Tokens.Hairline.default).frame(height: Tokens.Hairline.width)

            // Translation + an inline copy for the translated (native) text.
            HStack(alignment: .top, spacing: Tokens.Space.s8) {
                Text(block.ru)
                    .textStyle(Tokens.Text.body)
                    .foregroundStyle(Tokens.Content.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Tokens.Space.s8)
                CopyButton(block.ru, style: .icon,
                           accessibilityLabel: Loc.t("Скопировать перевод", "Copy translation"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    private var apiKeyBanner: some View {
        HStack(spacing: Tokens.Space.s12) {
            Image(systemName: "key.slash").foregroundStyle(Tokens.Signal.warning)
            Text(Loc.t("Нет ключа Claude API — перевод не загрузится. Добавьте ключ в Secrets.xcconfig.",
                       "No Claude API key — translation won't load. Add a key in Secrets.xcconfig."))
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s12)
        .glassPanel(cornerRadius: Tokens.Radius.control)
    }

    private var primingSheet: some View {
        VStack(spacing: Tokens.Space.s16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44))
                .foregroundStyle(Tokens.Content.primary)
                .padding(.top, Tokens.Space.s32)
            Text(Loc.t("Доступ к камере", "Camera access"))
                .textStyle(Tokens.Text.title2)
                .foregroundStyle(Tokens.Content.primary)
            Text(Loc.t("Чтобы распознать английский текст на вывеске или в меню, приложению нужна камера. Фото никуда не отправляется без вашего действия.",
                       "To read English text on a sign or menu, the app needs the camera. Nothing is sent anywhere without your action."))
                .textStyle(Tokens.Text.body)
                .foregroundStyle(Tokens.Content.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Tokens.Space.s24)
            Spacer()
            VStack(spacing: Tokens.Space.s8) {
                EHButton(Loc.t("Разрешить", "Allow"), kind: .primary, fillWidth: true) { model.confirmCameraPriming() }
                EHButton(Loc.t("Не сейчас", "Not now"), kind: .ghost, fillWidth: true) { model.cancelCameraPriming() }
            }
            .padding(.horizontal, Tokens.Space.s20)
            .padding(.bottom, Tokens.Space.s24)
        }
        .frame(maxWidth: .infinity)
        .background(Tokens.Surface.background)
        .presentationDetents([.medium])
    }

    private var uiImage: UIImage? {
        model.imageData.flatMap(UIImage.init(data:))
    }

    /// Run the CPU-heavy downscale/JPEG-encode on a background task so it never hitches the main
    /// thread (it was previously synchronous on the @MainActor View, stalling the UI as the camera
    /// sheet dismissed). Returns nil if the data isn't a decodable image.
    private static func prepareDetached(_ data: Data) async -> Data? {
        await Task.detached { prepareImageData(data) }.value
    }

    /// Downscale (max 1536px) and re-encode to JPEG: keeps the upload small and a format Claude accepts.
    /// `nonisolated static` so it can run off the main actor.
    nonisolated private static func prepareImageData(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxDimension: CGFloat = 1536
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rendered: UIImage = scale < 1
            ? UIGraphicsImageRenderer(size: target).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
              }
            : image
        return rendered.jpegData(compressionQuality: 0.8)
    }
}

/// Glass-styled label for the library PhotosPicker (its own View so the @MainActor `glassPanel`
/// isn't called from the picker's nonisolated label closure).
private struct LibraryButtonLabel: View {
    var body: some View {
        HStack(spacing: Tokens.Space.s8) {
            Image(systemName: "photo.on.rectangle")
            Text(Loc.t("Из галереи", "From library"))
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(Tokens.Content.primary)
        .frame(height: 50)
        .frame(maxWidth: .infinity)
        .glassPanel(cornerRadius: Tokens.Radius.pill)
    }
}
