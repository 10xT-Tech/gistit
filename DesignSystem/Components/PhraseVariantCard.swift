//
//  PhraseVariantCard.swift
//  EnglishHelper — DesignSystem
//
//  One "how to say it" variant: English phrase + register tag + Russian context. Tap = play TTS,
//  bookmark = save to study list.
//

import SwiftUI
import UIKit

public struct PhraseVariantCard: View {
    private let english: String
    private let register: RegisterLevel
    private let contextRU: String
    private let isSaved: Bool
    private let isPlaying: Bool
    private let onPlay: () -> Void
    private let onToggleSave: () -> Void
    /// Optional "explain this variant" affordance — routes into the Explain engine for this variant,
    /// contrasted against its siblings. Rendered as a lightbulb icon in the action row when provided.
    private let onExplain: (() -> Void)?

    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(english: String, register: RegisterLevel, contextRU: String,
                isSaved: Bool, isPlaying: Bool,
                onPlay: @escaping () -> Void, onToggleSave: @escaping () -> Void,
                onExplain: (() -> Void)? = nil) {
        self.english = english
        self.register = register
        self.contextRU = contextRU
        self.isSaved = isSaved
        self.isPlaying = isPlaying
        self.onPlay = onPlay
        self.onToggleSave = onToggleSave
        self.onExplain = onExplain
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            HStack(alignment: .top) {
                RegisterTagView(register)
                Spacer(minLength: Tokens.Space.s8)
                HStack(spacing: Tokens.Space.s16) {
                    // Play sits in the same action row as copy + save (tapping the card text also
                    // starts/stops playback — see .onTapGesture below).
                    Button(action: onPlay) {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                            .symbolEffect(.variableColor.iterative, isActive: isPlaying && !reduceMotion)
                            .foregroundStyle(isPlaying ? Tokens.Content.primary : Tokens.Content.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(DSLoc.t("Озвучить", "Play"))

                    // Explain (lightbulb) sits between play and copy — order: play · explain · copy · save.
                    if let onExplain {
                        Button(action: onExplain) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                                .foregroundStyle(Tokens.Content.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(DSLoc.t("Объяснить этот вариант", "Explain this variant"))
                    }

                    Button(action: copyToClipboard) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                            .foregroundStyle(copied ? Tokens.Signal.success : Tokens.Content.tertiary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(DSLoc.t("Скопировать английский", "Copy English"))

                    ShareButton(english, style: .icon,
                                accessibilityLabel: DSLoc.t("Поделиться фразой", "Share phrase"))

                    Button(action: onToggleSave) {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .font(.system(size: Tokens.Icon.cardActionProminent, weight: .medium))
                            .foregroundStyle(isSaved ? Tokens.Content.primary : Tokens.Content.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSaved ? DSLoc.t("Убрать из изучаемого", "Remove from study list") : DSLoc.t("Сохранить в изучаемое", "Save to study list"))
                }
            }

            Text(english)
                .textStyle(Tokens.Text.headline)
                .foregroundStyle(Tokens.Content.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(contextRU)
                .textStyle(Tokens.Text.subhead)
                .foregroundStyle(Tokens.Content.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(english). \(register.localizedName). \(contextRU)")
        .accessibilityHint(DSLoc.t("Дважды коснитесь, чтобы озвучить", "Double-tap to play"))
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            Button(DSLoc.t("Скопировать", "Copy")) { copyToClipboard() }
            Button(DSLoc.t("Поделиться", "Share")) { ShareSheetPresenter.share(english) }
            Button(isSaved ? DSLoc.t("Убрать из изучаемого", "Remove from study list") : DSLoc.t("Сохранить", "Save")) { onToggleSave() }
            if let onExplain {
                Button(DSLoc.t("Объяснить этот вариант", "Explain this variant")) { onExplain() }
            }
        }
    }

    // Inline copy (kept rather than a nested CopyButton so it folds into the card's combined
    // accessibility element); timing/animation match CopyButton so feedback is consistent app-wide.
    private func copyToClipboard() {
        UIPasteboard.general.string = english
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(Tokens.Motion.quick) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Tokens.Motion.quick) { copied = false }
        }
    }
}
