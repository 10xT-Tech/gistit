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
            finished
        case .studying:
            if let card = model.current {
                studying(card)
            }
        }
    }

    // MARK: Finished

    /// The set is done: today against the goal, and another set while cards are waiting.
    private var finished: some View {
        let plan = model.plan
        let reached = plan?.goalReached == true
        return VStack(spacing: Tokens.Space.s16) {
            Spacer()
            Image(systemName: reached ? "checkmark.seal.fill" : "checkmark.seal")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Tokens.Content.primary)
                .accessibilityHidden(true)
            Text(reached ? Loc.t("Цель на сегодня выполнена", "Today's goal reached")
                         : Loc.t("На сегодня всё", "All done for today"))
                .textStyle(Tokens.Text.title2)
                .foregroundStyle(Tokens.Content.primary)
                .multilineTextAlignment(.center)
            if let plan {
                GoalProgress(plan: plan)
                    .frame(maxWidth: 280)
            }
            if !model.canStudyMore {
                Text(Loc.t("Больше карточек на сегодня нет — возвращайтесь завтра.",
                           "No more cards for today — come back tomorrow."))
                    .textStyle(Tokens.Text.subhead)
                    .foregroundStyle(Tokens.Content.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            if model.canStudyMore, let plan {
                EHButton(Loc.t("Ещё \(plan.moreSize)", "\(plan.moreSize) more", "\(plan.moreSize) de plus",
                               "\(plan.moreSize) más", "\(plan.moreSize) weitere", "Altre \(plan.moreSize)"),
                         icon: "plus", kind: .primary, fillWidth: true, accessibilityID: "flashcards.more") {
                    Task { await model.more() }
                }
            }
            EHButton(Loc.t("Закрыть", "Close"), kind: model.canStudyMore ? .tonal : .primary, fillWidth: true,
                     accessibilityID: "flashcards.done", action: onClose)
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

            // A long card (an example, synonyms and notes at the larger sizes) scrolls inside the card.
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s16) {
                    Text(recognition ? expression.en : expression.ru)
                        .textStyle(Tokens.Flashcard.prompt)
                        .foregroundStyle(Tokens.Content.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    if model.isRevealed {
                        Divider().overlay(Tokens.Hairline.default)
                        CardBack(answer: recognition ? expression.ru : expression.en, expression: expression)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
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

    /// All four look the same — none is pre-selected; the user rates every card afresh.
    private func ratingButton(_ rating: ReviewRating) -> some View {
        let interval = model.intervals[rating].map(FlashcardSessionViewModel.intervalLabel) ?? ""
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
            .foregroundStyle(Tokens.Content.primary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Tokens.Fill.default,
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

/// "Today: 12 of 50" with a bar — the session's end and the dashboard.
struct GoalProgress: View {
    let plan: DailyPlan

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            ProgressView(value: Double(min(plan.studied, plan.goal)), total: Double(max(plan.goal, 1)))
                .tint(Tokens.Content.primary)
            Text(Loc.t("Сегодня: \(plan.studied) из \(plan.goal)", "Today: \(plan.studied) of \(plan.goal)",
                       "Aujourd'hui : \(plan.studied) sur \(plan.goal)", "Hoy: \(plan.studied) de \(plan.goal)",
                       "Heute: \(plan.studied) von \(plan.goal)", "Oggi: \(plan.studied) di \(plan.goal)"))
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("flashcards.goalProgress")
    }
}

/// The back of a flashcard: the answer (as large as the prompt), then the example, synonyms and the
/// context note — shared by practice and the In-flashcards card view.
struct CardBack: View {
    let answer: String
    let expression: Domain.Expression

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            Text(answer)
                .textStyle(Tokens.Flashcard.answer)
                .foregroundStyle(Tokens.Content.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !expression.example.isEmpty {
                Text(expression.example)
                    .textStyle(Tokens.Flashcard.example)
                    .italic()
                    .foregroundStyle(Tokens.Content.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !expression.synonyms.isEmpty {
                Text("≈ " + expression.synonyms.joined(separator: " · "))
                    .textStyle(Tokens.Flashcard.note)
                    .foregroundStyle(Tokens.Content.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !expression.context.isEmpty {
                Text(expression.context)
                    .textStyle(Tokens.Flashcard.note)
                    .foregroundStyle(Tokens.Content.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
