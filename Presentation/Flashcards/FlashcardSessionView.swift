//
//  FlashcardSessionView.swift
//  EnglishHelper — Presentation
//
//  Full-screen flashcard practice: the prompt on a glass card (tap it or "Show answer" to reveal),
//  then four rating buttons, each labelled with when the card would come back.
//

import SwiftUI
import Domain
import DesignSystem

public struct FlashcardSessionView: View {
    @State private var model: FlashcardSessionViewModel
    private let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: FlashcardSessionViewModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            ScreenBackground()
            VStack(spacing: Tokens.Space.s16) {
                topBar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)   // keeps the close button at the top
            }
            .padding(.horizontal, Tokens.Space.s20)
            .padding(.bottom, Tokens.Space.s16)
        }
        .task { await model.start() }
        .sensoryFeedback(.selection, trigger: model.reviewedCount)
        .alert(Loc.t("Карточки", "Flashcards"), isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Tokens.Content.primary)
                    .frame(width: 44, height: 44)
                    .glassPanel(cornerRadius: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Loc.t("Закрыть", "Close"))
            .accessibilityIdentifier("flashcards.close")
            Spacer()
            if model.phase == .studying {
                Text(Loc.t("Осталось: \(model.remaining)", "\(model.remaining) left",
                           "Restantes : \(model.remaining)", "Quedan: \(model.remaining)",
                           "Noch \(model.remaining)", "Rimanenti: \(model.remaining)"))
                    .textStyle(Tokens.Text.subhead)
                    .foregroundStyle(Tokens.Content.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.top, Tokens.Space.s8)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            LoadingView(Loc.t("Загружаю…", "Loading…"))
        case .failed:
            StatusView(systemImage: "exclamationmark.triangle", title: Loc.t("Не удалось загрузить", "Couldn't load"),
                       message: model.errorMessage,
                       actionTitle: Loc.t("Повторить", "Retry"), action: { Task { await model.start() } })
        case .finished:
            StatusView(systemImage: "checkmark.seal",
                       title: Loc.t("На сегодня всё", "All done for today"),
                       message: model.reviewedCount == 0
                           ? Loc.t("Карточек к повторению нет — возвращайтесь завтра.",
                                   "No cards to review — come back tomorrow.")
                           : Loc.t("Ответов: \(model.reviewedCount). Следующие карточки придут по расписанию.",
                                   "Answers: \(model.reviewedCount). The next cards will come on schedule.",
                                   "Réponses : \(model.reviewedCount). Les prochaines cartes arriveront selon le planning.",
                                   "Respuestas: \(model.reviewedCount). Las siguientes tarjetas llegarán según lo previsto.",
                                   "Antworten: \(model.reviewedCount). Die nächsten Karten kommen nach Plan.",
                                   "Risposte: \(model.reviewedCount). Le prossime schede arriveranno secondo il piano."),
                       actionTitle: Loc.t("Закрыть", "Close"), action: onClose)
                .accessibilityIdentifier("flashcards.done")
        case .studying:
            if let card = model.current {
                studying(card)
            }
        }
    }

    // MARK: Card

    private func studying(_ flashcard: Flashcard) -> some View {
        VStack(spacing: Tokens.Space.s16) {
            cardFace(flashcard)
                .id(flashcard.id)   // a fresh card slides in rather than morphing out of the last one
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                                  removal: .move(edge: .leading).combined(with: .opacity)))
            controls
        }
        .animation(reduceMotion ? nil : Tokens.Motion.standard, value: flashcard.id)
        .animation(reduceMotion ? nil : Tokens.Motion.standard, value: model.isRevealed)
    }

    private func cardFace(_ flashcard: Flashcard) -> some View {
        let expression = flashcard.expression
        let recognition = flashcard.card.direction == .recognition
        let studiedVisible = recognition || model.isRevealed
        return VStack(alignment: .leading, spacing: Tokens.Space.s16) {
            HStack {
                Text(recognition ? Loc.t("Что это значит?", "What does it mean?")
                                 : Loc.t("Как это сказать?", "How do you say it?"))
                    .textStyle(Tokens.Text.footnote)
                    .foregroundStyle(Tokens.Content.tertiary)
                Spacer()
                if studiedVisible {
                    Button { model.play() } label: {
                        Image(systemName: model.isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .symbolEffect(.variableColor.iterative, isActive: model.isPlaying && !reduceMotion)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(model.isPlaying ? Tokens.Content.primary : Tokens.Content.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Loc.t("Озвучить", "Play"))
                }
            }

            Text(recognition ? expression.en : expression.ru)
                .textStyle(Tokens.Text.title1)
                .foregroundStyle(Tokens.Content.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if model.isRevealed {
                Divider().overlay(Tokens.Hairline.default)
                VStack(alignment: .leading, spacing: Tokens.Space.s12) {
                    Text(recognition ? expression.ru : expression.en)
                        .textStyle(Tokens.Text.title2)
                        .foregroundStyle(Tokens.Content.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !expression.example.isEmpty {
                        Text(expression.example)
                            .textStyle(Tokens.Text.body)
                            .italic()
                            .foregroundStyle(Tokens.Content.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !expression.synonyms.isEmpty {
                        Text("≈ " + expression.synonyms.joined(separator: " · "))
                            .textStyle(Tokens.Text.subhead)
                            .foregroundStyle(Tokens.Content.tertiary)
                    }
                    if !expression.context.isEmpty {
                        Text(expression.context)
                            .textStyle(Tokens.Text.footnote)
                            .foregroundStyle(Tokens.Content.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Tokens.Space.s20)
        .glassPanel(cornerRadius: Tokens.Radius.card)
        .contentShape(Rectangle())
        .onTapGesture { model.reveal() }
        .accessibilityAction(named: Loc.t("Показать ответ", "Show answer")) { model.reveal() }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        if model.isRevealed {
            HStack(spacing: Tokens.Space.s8) {
                ForEach(ReviewRating.allCases, id: \.self) { rating in
                    ratingButton(rating)
                }
            }
        } else {
            EHButton(Loc.t("Показать ответ", "Show answer"), kind: .primary, fillWidth: true,
                     accessibilityID: "flashcards.reveal") { model.reveal() }
        }
    }

    private func ratingButton(_ rating: ReviewRating) -> some View {
        let interval = model.intervals[rating].map(FlashcardSessionViewModel.intervalLabel) ?? ""
        let primary = rating == .good
        return Button { model.rate(rating) } label: {
            VStack(spacing: 2) {
                Text(title(rating))
                    .textStyle(Tokens.Text.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(interval)
                    .textStyle(Tokens.Text.caption)
                    .opacity(0.7)
            }
            .foregroundStyle(primary ? Tokens.Content.onInvert : Tokens.Content.primary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(primary ? Tokens.Surface.invert : Tokens.Fill.default,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title(rating)), \(interval)")
        .accessibilityIdentifier("flashcards.rate.\(rating)")
    }

    private func title(_ rating: ReviewRating) -> String {
        switch rating {
        case .again: Loc.t("Снова", "Again")
        case .hard: Loc.t("Трудно", "Hard")
        case .good: Loc.t("Хорошо", "Good")
        case .easy: Loc.t("Легко", "Easy")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil && model.phase == .studying },
                set: { if !$0 { model.clearError() } })
    }
}
