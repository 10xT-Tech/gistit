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
//  The committed text only ever grows, and a session can run for hours. A pane is therefore NOT one
//  `Text` with the whole transcript (it was: laid out and drawn again in full on every update,
//  several times a second — on the Simulator 11–200 ms an update for one to three hours of speech,
//  32 ms for eight) but a stack of `Text`s, each a block of whole paragraphs (`TranscriptBlocks`):
//  an update touches the last one only (1–3 ms; 10 ms at eight hours). Still a plain, non-lazy
//  stack — the scroll sync works on the real content height.
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
                shareLabel: Loc.t("Поделиться распознанным текстом", "Share the recognized text"),
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
                shareLabel: Loc.t("Поделиться переводом", "Share translation"),
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
    let shareLabel: String
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
                        HStack(spacing: Tokens.Space.s16) {
                            CopyButton(copyText, style: .icon, accessibilityLabel: copyLabel)
                            ShareButton(copyText, style: .icon, accessibilityLabel: shareLabel)
                        }
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
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            // The headerless (Original) pane gets floating copy + share icons in its top-right corner.
            .overlay(alignment: .topTrailing) {
                if !showsTitle, !copyText.isEmpty {
                    HStack(spacing: Tokens.Space.s16) {
                        CopyButton(copyText, style: .icon, accessibilityLabel: copyLabel)
                        ShareButton(copyText, style: .icon, accessibilityLabel: shareLabel)
                    }
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
            .onChange(of: ShownText(final: finalText, pending: pendingText)) { _, _ in
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

    /// What the pane shows — compared, not concatenated, to notice new text.
    private struct ShownText: Equatable {
        let final: String
        let pending: String
    }

    @ViewBuilder private var transcriptText: some View {
        if finalText.isEmpty && pendingText.isEmpty {
            Text(placeholder)
                .textStyle(Tokens.Text.body)
                .foregroundStyle(Tokens.Content.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            TranscriptText(finalText: finalText, pendingText: pendingText)
        }
    }
}

/// The committed text of a pane cut into BLOCKS of whole paragraphs, so that each block is a
/// `Text` of its own. Paragraphs are separated by an empty line ("\n\n" — an utterance ended, or
/// the divider of a direction switch); a block is closed at the first such break after it has
/// `blockSize` of text — a rule of the text BEFORE the break only, so a block, once closed, never
/// changes however the text grows. Every closed block KEEPS the first of the two line breaks: a
/// `Text` ending in a line break draws the empty line itself, so the stack measures what the one
/// `Text` did (to a fraction of a point a block — each `Text` rounds its own height).
/// `closed.joined(separator: "\n") + "\n" + open` is the text again.
///
/// Cut INCREMENTALLY (`take`): the text only grows, so each update reads what came after the last
/// closed block — not the whole transcript again, which is the cost this type exists to remove.
struct TranscriptBlocks: Equatable {
    /// About two minutes of speech: an hour is a few dozen `Text`s, and laying out the open one on
    /// every update is nothing.
    static let blockSize = 2_000

    /// Finished blocks, each with its trailing line break.
    private(set) var closed: [String] = []
    /// The text still being written (empty right after a break that closed a block) — the
    /// provisional tail follows it.
    private(set) var open = ""
    /// UTF-8 length of the text the closed blocks were cut from, both line breaks of each included.
    private var closedLength = 0

    init() {}

    init(_ text: String, blockSize: Int = TranscriptBlocks.blockSize) {
        take(text, blockSize: blockSize)
    }

    /// The text as it is now: the same text grown (the usual case — only its new end is read), or
    /// another one (a new session), cut from the start.
    mutating func take(_ text: String, blockSize: Int = TranscriptBlocks.blockSize) {
        if !isCutFromTheStart(of: text) {
            closed = []
            closedLength = 0
        }
        let utf8 = text.utf8
        var start = utf8.index(utf8.startIndex, offsetBy: closedLength)
        var index = start
        var size = 0
        while index != utf8.endIndex {
            let next = utf8.index(after: index)
            size += 1
            if size >= blockSize, utf8[index] == 0x0A, next != utf8.endIndex, utf8[next] == 0x0A {
                closed.append(String(text[start..<next]))      // through the FIRST line break
                closedLength += size + 1
                start = utf8.index(after: next)
                index = start
                size = 0
            } else {
                index = next
            }
        }
        open = String(text[start...])
    }

    /// Whether `text` still begins with what the closed blocks were cut from. Told by the LAST
    /// closed block being where it was (comparing the whole beginning would read the whole
    /// transcript on every update).
    private func isCutFromTheStart(of text: String) -> Bool {
        guard let last = closed.last else { return true }
        let utf8 = text.utf8
        guard utf8.count >= closedLength else { return false }
        let end = utf8.index(utf8.startIndex, offsetBy: closedLength)
        let from = utf8.index(end, offsetBy: -(last.utf8.count + 1))
        return utf8[from..<end].elementsEqual((last + "\n").utf8)
    }
}

/// A pane's transcript: committed text primary, the provisional tail tertiary, replaced live as
/// recognition firms up. One `Text` per block — see the file header.
struct TranscriptText: View {
    let finalText: String
    let pendingText: String
    var blockSize = TranscriptBlocks.blockSize

    /// The blocks cut so far, kept between updates. A reference filled in while the body is
    /// evaluated — it holds nothing the view should be redrawn for.
    @State private var cut = Cut()

    private final class Cut {
        var blocks = TranscriptBlocks()
    }

    var body: some View {
        let blocks = blocks(of: finalText)
        // Right after a break that closed a block there is nothing below it yet: the line the next
        // words will stand on is kept (the one `Text` drew it too), so the pane doesn't jump.
        let open = blocks.open.isEmpty && pendingText.isEmpty && !blocks.closed.isEmpty ? " " : blocks.open
        // The spacing between two `Text`s = the line spacing inside one: together with the line
        // break each closed block keeps, the stack is the single `Text`, line for line.
        VStack(alignment: .leading, spacing: Tokens.Text.body.lineSpacing) {
            ForEach(blocks.closed.indices, id: \.self) { index in
                ClosedBlock(text: blocks.closed[index])
                    .equatable()
            }
            // The open text and the tail stay in ONE Text (interpolation, not `+` — deprecated in
            // iOS 26): the tail continues the line the committed text ends on.
            Text("\(Text(open).foregroundStyle(Tokens.Content.primary))\(Text(pendingText).foregroundStyle(Tokens.Content.tertiary))")
                .textStyle(Tokens.Text.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func blocks(of text: String) -> TranscriptBlocks {
        cut.blocks.take(text, blockSize: blockSize)
        return cut.blocks
    }

    /// Equatable: a block that hasn't changed (none of the closed ones ever does) is neither
    /// rebuilt nor laid out again when the text below it grows.
    private struct ClosedBlock: View, Equatable {
        let text: String

        var body: some View {
            Text(text)
                .textStyle(Tokens.Text.body)
                .foregroundStyle(Tokens.Content.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
