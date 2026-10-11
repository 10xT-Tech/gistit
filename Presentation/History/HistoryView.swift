//
//  HistoryView.swift
//  EnglishHelper — Presentation
//
//  "История" — read-only log. Tap a row to review the full result.
//

import SwiftUI
import Foundation
import Domain
import DesignSystem

public struct HistoryView: View {
    @State private var model: HistoryViewModel

    public init(model: HistoryViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                contentSection
            }
            .navigationTitle(Loc.t("История", "History"))
            .settingsTrigger()
            .navigationDestination(for: HistoryEntry.self) { entry in
                HistoryDetailView(model: model.makeDetailViewModel(for: entry))
            }
            .task { await model.load() }
            .alert(Loc.t("История", "History"), isPresented: actionErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
        }
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.clearActionError() } })
    }

    @ViewBuilder private var contentSection: some View {
        switch model.phase {
        case .loading:
            LoadingView(Loc.t("Загружаю…", "Loading…"))
        case .failed:
            StatusView(systemImage: "exclamationmark.triangle", title: Loc.t("Не удалось загрузить", "Couldn't load"),
                       message: model.errorMessage,
                       actionTitle: Loc.t("Повторить", "Retry"), action: { Task { await model.load() } })
        case .empty:
            StatusView(systemImage: "clock.arrow.circlepath", title: Loc.t("История пуста", "No history yet"),
                       message: Loc.t("Здесь появятся ваши запросы: «Как сказать», переводы и фото-переводы.",
                                      "Your requests will appear here: how-to-say, translations, and photo translations."))
        case .loaded:
            List {
                ForEach(model.entries) { entry in
                    NavigationLink(value: entry) { HistoryRow(entry: entry) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: Tokens.Space.s4, leading: Tokens.Space.s16,
                                                  bottom: Tokens.Space.s4, trailing: Tokens.Space.s16))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { model.delete(entry) } label: {
                                Label(Loc.t("Удалить", "Delete"), systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Row

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: Tokens.Space.s12) {
            Image(systemName: kindIcon(entry.kind))
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Tokens.Content.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                Text(kindTitle(entry.kind))
                    .textStyle(Tokens.Text.caption2)
                    .foregroundStyle(Tokens.Content.tertiary)
                Text(entry.inputText)
                    .textStyle(Tokens.Text.headline)
                    .foregroundStyle(Tokens.Content.primary)
                    .lineLimit(1)
                Text(resultSnippet(entry.result))
                    .textStyle(Tokens.Text.subhead)
                    .foregroundStyle(Tokens.Content.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Tokens.Space.s8)
            // No in-card chevron — the NavigationLink already shows the system disclosure arrow.
        }
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kindTitle(entry.kind)). \(entry.inputText)")
        .accessibilityHint(Loc.t("Открыть результат", "Open result"))
    }
}

// MARK: - Detail (read-only)

private struct HistoryDetailView: View {
    @State private var model: HistoryDetailViewModel
    @Environment(AppUIState.self) private var ui

    init(model: HistoryDetailViewModel) {
        self.model = model
    }

    private var entry: HistoryEntry { model.entry }

    var body: some View {
        VerticalScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s16) {
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .textStyle(Tokens.Text.footnote)
                    .foregroundStyle(Tokens.Content.tertiary)

                // For translate/photo the request text IS the studied-language rendering, so its
                // playback (in the studied voice), copy, and explain sit in the card header — the same
                // icon row as the phrase cards. A live session's REAL recording also belongs here:
                // it is the original of the request, not part of the translation below.
                labeledCard(title: Loc.t("Запрос", "Request"),
                            actions: { if isPlayableSource { requestActions } }) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s12) {
                        // The RECORDING comes first — it IS the original; the recognized text
                        // below is derived from it.
                        if case .liveTranslation(_, _, _, let duration) = entry.result,
                           model.recordingFileName != nil {
                            recordingRow(duration: duration)
                            Rectangle().fill(Tokens.Hairline.default).frame(height: Tokens.Hairline.width)
                        }
                        Text(entry.inputText)
                            .textStyle(Tokens.Text.body)
                            .foregroundStyle(Tokens.Content.primary)
                    }
                }

                resultSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Space.s20)
        }
        .background(ScreenBackground())
        .navigationTitle(kindTitle(entry.kind))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadSavedState() }
        // A minutes-long session recording must not keep playing after the screen is gone.
        .onDisappear { model.stopRecordingPlayback() }
        .alert(Loc.t("Изучаемое", "Study list"), isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        // Recording-playback failures carry their own, correctly-titled alert.
        .alert(Loc.t("Запись", "Recording", "Enregistrement", "Grabación", "Aufnahme", "Registrazione"),
               isPresented: playbackErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.playbackError ?? "")
        }
    }

    private var playbackErrorBinding: Binding<Bool> {
        Binding(get: { model.playbackError != nil }, set: { if !$0 { model.clearPlaybackError() } })
    }

    @ViewBuilder private var resultSection: some View {
        switch entry.result {
        case .howToSay(let variants), .whatToSay(let variants):
            VStack(spacing: Tokens.Space.s12) {
                ForEach(variants) { variant in
                    // Same card as the Voice screen: tap = play, bookmark = save.
                    PhraseVariantCard(
                        english: variant.en,
                        register: registerLevel(variant.register),
                        contextRU: variant.contextRU,
                        isSaved: model.isSaved(HistoryDetailViewModel.variantKey(variant)),
                        isPlaying: model.isPlaying(HistoryDetailViewModel.variantKey(variant)),
                        onPlay: { model.playVariant(variant) },
                        onToggleSave: { model.toggleSaveVariant(variant) },
                        onExplain: { ui.pendingExplain = ExplainRequest(
                            text: variant.en,
                            alternatives: variants.filter { $0.id != variant.id }.map(\.en)) }
                    )
                }
            }
        case .translate(let ru), .photoTranslate(let ru):
            VStack(alignment: .leading, spacing: Tokens.Space.s12) {
                HStack {
                    sectionTitle(Loc.t("Перевод", "Translation"))
                    Spacer(minLength: Tokens.Space.s8)
                    // Copy sits in the header next to the bookmark — same icon row as the phrase cards.
                    HStack(spacing: Tokens.Space.s16) {
                        CopyButton(ru, style: .icon,
                                   accessibilityLabel: Loc.t("Скопировать перевод", "Copy translation"))
                        bookmark(isSaved: model.isSaved(HistoryDetailViewModel.translationKey)) {
                            model.toggleSaveTranslation()
                        }
                    }
                }
                Text(ru)
                    .textStyle(Tokens.Text.title3)
                    .foregroundStyle(Tokens.Content.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Space.s16)
            .glassPanel(cornerRadius: Tokens.Radius.card)

        case .photoExplain(let title, let details):
            // Same shape as the See-it explanation card: title + hairline + details, copyable.
            // The "Запрос" card above shows the title too (it doubles as inputText) — acceptable
            // duplication; the photo itself was never persisted.
            VStack(alignment: .leading, spacing: Tokens.Space.s12) {
                HStack {
                    sectionTitle(Loc.t("Объяснение", "Explanation", "Explication", "Explicación",
                                       "Erklärung", "Spiegazione"))
                    Spacer(minLength: Tokens.Space.s8)
                    CopyButton(title + "\n\n" + details, style: .icon,
                               accessibilityLabel: Loc.t("Скопировать объяснение", "Copy explanation"))
                }
                Text(title)
                    .textStyle(Tokens.Text.headline)
                    .foregroundStyle(Tokens.Content.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(Tokens.Hairline.default).frame(height: Tokens.Hairline.width)
                Text(details)
                    .textStyle(Tokens.Text.body)
                    .foregroundStyle(Tokens.Content.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Space.s16)
            .glassPanel(cornerRadius: Tokens.Radius.card)

        case .liveTranslation(_, let ru, _, _):
            // The recognized speech AND its recording live in the "Запрос" card above; here — the
            // translation only.
            VStack(alignment: .leading, spacing: Tokens.Space.s12) {
                HStack {
                    sectionTitle(Loc.t("Перевод", "Translation"))
                    Spacer(minLength: Tokens.Space.s8)
                    CopyButton(ru, style: .icon,
                               accessibilityLabel: Loc.t("Скопировать перевод", "Copy translation"))
                }
                Text(ru)
                    .textStyle(Tokens.Text.body)
                    .foregroundStyle(Tokens.Content.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Space.s16)
            .glassPanel(cornerRadius: Tokens.Radius.card)
        }
    }

    /// Play/stop of the ORIGINAL session audio + duration; a thin progress bar while playing.
    private func recordingRow(duration: TimeInterval) -> some View {
        HStack(spacing: Tokens.Space.s12) {
            Button { model.toggleRecordingPlayback() } label: {
                Image(systemName: model.isPlayingRecording ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Tokens.Content.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPlayingRecording
                ? Loc.t("Остановить запись", "Stop the recording")
                : Loc.t("Прослушать оригинальную запись", "Play the original recording"))

            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                Text(Loc.t("Оригинальная запись", "Original recording", "Enregistrement original",
                           "Grabación original", "Originalaufnahme", "Registrazione originale"))
                    .textStyle(Tokens.Text.subhead)
                    .foregroundStyle(Tokens.Content.primary)
                if model.isPlayingRecording {
                    ProgressView(value: model.recordingProgress)
                        .tint(Tokens.Content.primary)
                } else {
                    Text(Self.durationLabel(duration))
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Content.tertiary)
                }
            }
        }
    }

    private static func durationLabel(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Translate / photo requests store the studied-language rendering as the request text, so it's
    /// playable (in the studied voice). A how-to-say request is a raw intent — not played; a live
    /// session has the REAL recording instead of TTS.
    private var isPlayableSource: Bool {
        switch entry.kind {
        case .translate, .photoTranslate: true
        // photoExplain's inputText is the native-language TITLE — nothing to speak in the studied voice.
        case .howToSay, .whatToSay, .photoExplain, .liveTranslation: false
        }
    }

    /// Play · Explain · Copy on the studied-language request — icon-only, matching the phrase cards.
    private var requestActions: some View {
        let playing = model.isPlaying(HistoryDetailViewModel.translationKey)
        return HStack(spacing: Tokens.Space.s16) {
            Button { model.playTranslationSource() } label: {
                Image(systemName: playing ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                    .symbolEffect(.variableColor.iterative, isActive: playing)
                    .foregroundStyle(playing ? Tokens.Content.primary : Tokens.Content.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Loc.t("Озвучить", "Play"))

            Button { ui.pendingExplain = ExplainRequest(text: entry.inputText) } label: {
                Image(systemName: "lightbulb")
                    .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                    .foregroundStyle(Tokens.Content.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Loc.t("Объяснить", "Explain"))

            CopyButton(entry.inputText, style: .icon,
                       accessibilityLabel: Loc.t("Скопировать выражение", "Copy expression"))
        }
    }

    private func bookmark(isSaved: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: Tokens.Icon.cardActionProminent, weight: .medium))
                .foregroundStyle(isSaved ? Tokens.Content.primary : Tokens.Content.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSaved ? Loc.t("Убрать из изучаемого", "Remove from study list") : Loc.t("Сохранить в изучаемое", "Save to study list"))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .textStyle(Tokens.Text.caption2)
            .foregroundStyle(Tokens.Content.tertiary)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } })
    }

    /// The REQUEST block. Rendered as a FLAT, recessed tonal card (no glass blur, no stroke) so it
    /// reads as the quiet "what you asked" — visually distinct from the raised glass result cards.
    private func labeledCard<Actions: View, Content: View>(
        title: String,
        @ViewBuilder actions: () -> Actions = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            HStack(alignment: .center) {
                sectionTitle(title)
                Spacer(minLength: Tokens.Space.s8)
                actions()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Color(light: Color(hex: 0xE4E4EA), dark: .white.opacity(0.10)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Glass.border, lineWidth: Tokens.Hairline.width)
        )
    }
}

// MARK: - Shared helpers

private func kindIcon(_ kind: RequestKind) -> String {
    switch kind {
    case .howToSay: "quote.bubble"
    case .whatToSay: "bubble.left.and.bubble.right"
    case .translate: "character.bubble"
    case .photoTranslate: "camera"
    case .photoExplain: "sparkle.magnifyingglass"
    case .liveTranslation: "waveform"
    }
}

private func kindTitle(_ kind: RequestKind) -> String {
    switch kind {
    case .howToSay: Loc.t("Как сказать", "How to say")
    case .whatToSay: Loc.t("Что сказать", "What to say", "Quoi dire", "Qué decir", "Was sagen", "Cosa dire")
    case .translate: Loc.t("Перевод", "Translation")
    case .photoTranslate: Loc.t("Фото-перевод", "Photo translation")
    case .photoExplain: Loc.t("Фото-объяснение", "Photo explanation", "Explication photo",
                              "Explicación de foto", "Foto-Erklärung", "Spiegazione foto")
    case .liveTranslation: Loc.t("Онлайн-перевод", "Live translation", "Traduction en direct",
                                 "Traducción en vivo", "Live-Übersetzung", "Traduzione dal vivo")
    }
}

private func resultSnippet(_ result: RequestResult) -> String {
    switch result {
    case .howToSay(let variants), .whatToSay(let variants): variants.first?.en ?? "—"
    case .translate(let ru): ru
    case .photoTranslate(let ru): ru
    case .photoExplain(_, let details): details
    case .liveTranslation(_, let ru, _, _): ru
    }
}

private func registerLevel(_ register: Register) -> RegisterLevel {
    switch register {
    case .formal: .formal
    case .casual, .neutral: .casual
    case .slang: .slang
    }
}
