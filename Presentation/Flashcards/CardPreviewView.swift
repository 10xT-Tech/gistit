//
//  CardPreviewView.swift
//  EnglishHelper — Presentation
//
//  In flashcards → tap a phrase: the whole card at a glance — the phrase (with playback), its meaning,
//  example, synonyms and notes — and where each of its two cards stands: stage, how many times it was
//  answered, when it comes next. Read-only: no rating, nothing is written; it isn't practice.
//

import SwiftUI
import Domain
import DesignSystem

struct CardPreviewView: View {
    let expression: Domain.Expression
    let cards: [ReviewCard]
    let isPlaying: Bool
    let onPlay: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            VerticalScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s16) {
                    face
                    progress
                }
                .padding(Tokens.Space.s20)
            }
            .background(Tokens.Surface.background)
            .navigationTitle(Loc.t("Карточка", "Card"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Loc.t("Готово", "Done")) { dismiss() }
                        .accessibilityIdentifier("cardPreview.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Both sides on one card: the studied-language side, then the meaning side.
    private var face: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            HStack(alignment: .firstTextBaseline) {
                Text(expression.en)
                    .textStyle(Tokens.Flashcard.prompt)
                    .foregroundStyle(Tokens.Content.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Tokens.Space.s8)
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .symbolEffect(.variableColor.iterative, isActive: isPlaying && !reduceMotion)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(isPlaying ? Tokens.Content.primary : Tokens.Content.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Loc.t("Озвучить", "Play"))
            }
            Divider().overlay(Tokens.Hairline.default)
            CardBack(answer: expression.ru, expression: expression)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s20)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    /// One line per direction: "Recognize: young · reviews: 4 · next in 3 days".
    private var progress: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            ForEach(cards) { card in
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s8) {
                    Circle()
                        .fill(Tokens.Chart.stage[card.stage.rawValue])
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(CardStatusTag.direction(card.direction)): \(CardStatusTag.stage(card.stage))")
                            .textStyle(Tokens.Text.subhead)
                            .foregroundStyle(Tokens.Content.primary)
                        Text(details(card))
                            .textStyle(Tokens.Text.footnote)
                            .foregroundStyle(Tokens.Content.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
        .accessibilityIdentifier("cardPreview.progress")
    }

    private func details(_ card: ReviewCard) -> String {
        let reviews = Loc.t("повторений: \(card.reps)", "reviews: \(card.reps)", "révisions : \(card.reps)",
                            "repasos: \(card.reps)", "Wiederholungen: \(card.reps)", "ripassi: \(card.reps)")
        guard card.state != .new else {
            return reviews + " · " + Loc.t("ещё не изучалась", "not studied yet", "pas encore étudiée",
                                           "aún sin estudiar", "noch nicht gelernt", "non ancora studiata")
        }
        let next = card.due <= Date()
            ? Loc.t("повторить сейчас", "due now", "à revoir maintenant", "toca repasar", "jetzt fällig", "da ripassare ora")
            : Loc.t("следующее \(relative(card.due))", "next \(relative(card.due))", "prochaine \(relative(card.due))",
                    "siguiente \(relative(card.due))", "nächste \(relative(card.due))", "prossima \(relative(card.due))")
        return reviews + " · " + next
    }

    private func relative(_ date: Date) -> String {
        date.formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide, locale: locale))
    }
}
