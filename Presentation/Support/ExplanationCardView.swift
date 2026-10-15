//
//  ExplanationCardView.swift
//  EnglishHelper — Presentation
//
//  Renders an ExpressionExplanation: the studied-language headline (optional play + save) with its
//  own copy, the labelled native-language sections, and a separate copy for the explanation body —
//  each with a brief confirmation. Used by "Понять"/Get it (Explain mode).
//

import SwiftUI
import Domain
import DesignSystem

struct ExplanationCardView: View {
    private let studied: String
    private let explanation: ExpressionExplanation
    private let isPlaying: Bool
    private let onPlay: (() -> Void)?
    private let isSaved: Bool?
    private let onToggleSave: (() -> Void)?

    init(
        studied: String,
        explanation: ExpressionExplanation,
        isPlaying: Bool = false,
        onPlay: (() -> Void)? = nil,
        isSaved: Bool? = nil,
        onToggleSave: (() -> Void)? = nil
    ) {
        self.studied = studied
        self.explanation = explanation
        self.isPlaying = isPlaying
        self.onPlay = onPlay
        self.isSaved = isSaved
        self.onToggleSave = onToggleSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s16) {
            // Mode tag (left) + action icons (right) on their own row above the studied headline, which
            // sits full-width below — symmetric with the Translate card.
            HStack(spacing: Tokens.Space.s16) {
                CardTagView(Loc.t("Объяснение", "Explanation", "Explication", "Explicación", "Erklärung", "Spiegazione"))
                Spacer(minLength: Tokens.Space.s8)
                if let onPlay, !studied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { onPlay() } label: {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                            .foregroundStyle(isPlaying ? Tokens.Content.primary : Tokens.Content.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Loc.t("Озвучить", "Play"))
                }
                CopyButton(studied, style: .icon,
                           accessibilityLabel: Loc.t("Скопировать выражение", "Copy expression"))
                ShareButton(studied, style: .icon,
                            accessibilityLabel: Loc.t("Поделиться выражением", "Share expression"))
                if let isSaved, let onToggleSave {
                    Button { onToggleSave() } label: {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .font(.system(size: Tokens.Icon.cardActionProminent, weight: .medium))
                            .foregroundStyle(isSaved ? Tokens.Content.primary : Tokens.Content.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSaved
                        ? Loc.t("Убрать из изучаемого", "Remove from study list")
                        : Loc.t("Сохранить в изучаемое", "Save to study list"))
                }
            }

            Text(studied)
                .textStyle(Tokens.Text.headline)
                .foregroundStyle(Tokens.Content.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(Tokens.Hairline.default).frame(height: Tokens.Hairline.width)

            section(Loc.t("Значение", "Meaning"), explanation.meaning)
            section(Loc.t("Тон и регистр", "Tone & register"), explanation.register)
            section(Loc.t("В контексте", "In context"), explanation.context)
            section(Loc.t("Аналогия", "Analogy"), explanation.analogy)

            // Copy the explanation body (the labelled native-language sections) — separate from the
            // studied-text copy above.
            HStack(spacing: Tokens.Space.s20) {
                CopyButton(explanationText, style: .labeled,
                           accessibilityLabel: Loc.t("Скопировать объяснение", "Copy explanation"))
                ShareButton(explanationText, style: .labeled,
                            accessibilityLabel: Loc.t("Поделиться объяснением", "Share explanation"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    @ViewBuilder private func section(_ label: String, _ text: String) -> some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                Text(label.uppercased())
                    .textStyle(Tokens.Text.caption2)
                    .foregroundStyle(Tokens.Content.tertiary)
                Text(text)
                    .textStyle(Tokens.Text.body)
                    .foregroundStyle(Tokens.Content.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The explanation body as plain text — each non-empty section with its (uppercased) title — for
    /// the "copy explanation" action. The studied headline has its own separate copy control.
    private var explanationText: String {
        var parts: [String] = []
        func add(_ label: String, _ text: String) {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            parts.append("\(label.uppercased())\n\(body)")
        }
        add(Loc.t("Значение", "Meaning"), explanation.meaning)
        add(Loc.t("Тон и регистр", "Tone & register"), explanation.register)
        add(Loc.t("В контексте", "In context"), explanation.context)
        add(Loc.t("Аналогия", "Analogy"), explanation.analogy)
        return parts.joined(separator: "\n\n")
    }
}
