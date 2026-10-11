//
//  LiveTranscriptView.swift
//  EnglishHelper — Presentation
//
//  The Online-mode transcript: a SMALL pane (recognized speech, ~4 lines) above a BIG pane (live
//  translation, all remaining height). Both auto-stick to the bottom while text streams in; the
//  user can scroll up to read — streaming keeps appending below, and grabbing the bottom again
//  re-engages auto-follow. The panes are POSITION-SYNCED: dragging either one scrolls the other to
//  the same relative position (contents differ in length, so the sync is proportional).
//

import SwiftUI
import Domain
import DesignSystem

/// Shared scroll state of the two panes. `driverPane` is the pane the user is physically dragging —
/// the ONLY writer of `fraction` (the other pane follows), which is what prevents feedback loops.
/// (Top-level, not nested: the panes reference it without the view's generic parameter.)
struct LiveTranscriptSync: Equatable {
    var fraction: CGFloat = 1
    var driverPane: Int?
    var stickToBottom = true
}

struct LiveTranscriptView<Middle: View>: View {
    let text: LiveTranslationText
    let isStreaming: Bool
    /// Content height of the small (Original) pane — supplied by the SCREEN so it is the same
    /// single metric that sizes the text-modes' input box (the "first window" must match exactly).
    let smallPaneContentHeight: CGFloat
    /// Rendered BETWEEN the two panes — the screen puts the Listen control (+ its error line) here.
    @ViewBuilder let middle: () -> Middle

    @State private var sync = LiveTranscriptSync()

    var body: some View {
        VStack(spacing: Tokens.Space.s12) {
            TranscriptPane(
                paneID: 0,
                title: Loc.t("Оригинал", "Original", "Original", "Original", "Original", "Originale"),
                showsTitle: false,   // the small pane is self-evident — no header (VoiceOver keeps the name)
                copyLabel: Loc.t("Скопировать распознанный текст", "Copy the recognized text"),
                finalText: text.originalFinal,
                pendingText: text.originalPending,
                placeholder: isStreaming
                    ? Loc.t("Слушаю…", "Listening…")
                    : Loc.t("Здесь появится распознанная речь", "Recognized speech will appear here",
                            "La parole reconnue apparaîtra ici", "El habla reconocida aparecerá aquí",
                            "Erkannte Sprache erscheint hier", "Il parlato riconosciuto apparirà qui"),
                fixedHeight: smallPaneContentHeight,   // the spec: a four-line window
                sync: $sync
            )
            middle()
            TranscriptPane(
                paneID: 1,
                title: Loc.t("Перевод", "Translation", "Traduction", "Traducción", "Übersetzung", "Traduzione"),
                copyLabel: Loc.t("Скопировать перевод", "Copy translation"),
                finalText: text.translationFinal,
                pendingText: text.translationPending,
                placeholder: isStreaming
                    ? Loc.t("Перевожу…", "Translating…")
                    : Loc.t("Здесь побежит перевод в реальном времени", "The live translation will run here",
                            "La traduction en direct défilera ici", "La traducción en vivo correrá aquí",
                            "Die Live-Übersetzung läuft hier", "La traduzione dal vivo scorrerà qui"),
                fixedHeight: nil,                                // the rest of the screen
                sync: $sync
            )
        }
        // A NEW session starts with fresh text — re-engage auto-follow even if the user had
        // scrolled away (and paused it) during the previous session.
        .onChange(of: isStreaming) { _, streaming in
            if streaming { sync = LiveTranscriptSync() }
        }
    }
}

/// One scrollable transcript pane. Committed text renders primary; the provisional (pending) tail
/// renders tertiary and is replaced live as recognition firms up.
private struct TranscriptPane: View {
    let paneID: Int
    /// Used for the on-pane header (when `showsTitle`) AND always for the VoiceOver label.
    let title: String
    var showsTitle = true
    /// VoiceOver label of the pane's copy-to-clipboard button.
    let copyLabel: String
    let finalText: String
    let pendingText: String
    let placeholder: String
    /// Non-nil = fixed content height (the small pane); nil = greedy (the big pane).
    let fixedHeight: CGFloat?
    @Binding var sync: LiveTranscriptSync

    @State private var position = ScrollPosition()
    /// Scrollable span (content − container, ≥ 0) — needed to turn the shared fraction into an offset.
    @State private var span: CGFloat = 0

    private struct PaneGeometry: Equatable {
        var offset: CGFloat
        var span: CGFloat
    }

    /// What the copy button puts on the clipboard: exactly the visible transcript.
    private var copyText: String {
        (finalText + pendingText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            if showsTitle {
                HStack {
                    Text(title.uppercased())
                        .textStyle(Tokens.Text.caption2)
                        .foregroundStyle(Tokens.Content.tertiary)
                    Spacer(minLength: Tokens.Space.s8)
                    if !copyText.isEmpty {
                        CopyButton(copyText, style: .icon, accessibilityLabel: copyLabel)
                    }
                }
            }

            // A plain vertical ScrollView, NOT `VerticalScrollView`: that one pins its content to the
            // nearest container's width (`containerRelativeFrame`), which for a pane nested in a
            // non-scrolling layout is the whole screen — the text then outgrew the card and pushed both
            // panes past the screen edges. Here the pane's own width already bounds the text.
            ScrollView(.vertical) {
                transcriptText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            // The headerless (Original) pane gets a floating copy icon in its top-right corner.
            .overlay(alignment: .topTrailing) {
                if !showsTitle, !copyText.isEmpty {
                    CopyButton(copyText, style: .icon, accessibilityLabel: copyLabel)
                }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: PaneGeometry.self) { geometry in
                PaneGeometry(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                             span: max(0, geometry.contentSize.height - geometry.containerSize.height))
            } action: { _, new in
                span = new.span
                // Only the pane under the user's finger drives the shared position — the follower's
                // programmatic scrolls (which also land here) must not echo back.
                guard sync.driverPane == paneID else { return }
                let fraction = new.span > 0 ? min(1, max(0, new.offset / new.span)) : 1
                sync.fraction = fraction
                // Reaching the bottom re-engages auto-follow; anywhere above it pauses it.
                sync.stickToBottom = new.span <= 0 || fraction >= 0.98
            }
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .interacting {
                    sync.driverPane = paneID
                } else if newPhase == .idle, sync.driverPane == paneID {
                    sync.driverPane = nil
                }
            }
            .onChange(of: sync.fraction) { _, fraction in
                // Follow the OTHER pane's drag proportionally.
                guard let driver = sync.driverPane, driver != paneID else { return }
                position.scrollTo(y: fraction * span)
            }
            .onChange(of: finalText + "\u{1}" + pendingText) { _, _ in
                // New streamed text: keep the bottom in view unless the user scrolled away.
                guard sync.stickToBottom, sync.driverPane == nil else { return }
                position.scrollTo(edge: .bottom)
            }
            .frame(height: fixedHeight)
            .frame(maxHeight: fixedHeight == nil ? .infinity : nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(finalText) \(pendingText)")
    }

    @ViewBuilder private var transcriptText: some View {
        if finalText.isEmpty && pendingText.isEmpty {
            Text(placeholder)
                .textStyle(Tokens.Text.body)
                .foregroundStyle(Tokens.Content.tertiary)
        } else {
            // Text interpolation (not `+`, deprecated in iOS 26) keeps both runs in ONE Text so
            // wrapping + the paired auto-scroll geometry stay unchanged.
            Text("\(Text(finalText).foregroundStyle(Tokens.Content.primary))\(Text(pendingText).foregroundStyle(Tokens.Content.tertiary))")
                .textStyle(Tokens.Text.body)
        }
    }
}
