//
//  StudyDashboardView.swift
//  EnglishHelper — Presentation
//
//  The Study tab: a learning dashboard. Practice (due today, new, expressions in flashcards, Start —
//  Pro), the Caught and In-flashcards lists (pushed), answers per day for the last week, and how the
//  cards are distributed by stage. Charts follow the dataviz rules: the reviews bars are one series (one tone,
//  today emphasised), the stages are ordinal (the validated `Tokens.Chart.stage` ramp) with a legend
//  and counts, so nothing is told by tone alone; VoiceOver reads the numbers.
//

import SwiftUI
import Domain
import DesignSystem

public struct StudyDashboardView: View {
    @State private var model: StudyDashboardViewModel
    @State private var caught: StudyListViewModel
    @State private var studying: StudyListViewModel
    @State private var showCaught = false
    @State private var showStudying = false
    @Environment(AppUIState.self) private var ui
    @Environment(SubscriptionState.self) private var subscription

    public init(model: StudyDashboardViewModel, caught: StudyListViewModel, studying: StudyListViewModel) {
        self.model = model
        self.caught = caught
        self.studying = studying
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                if let stats = model.stats {
                    VerticalScrollView {
                        VStack(spacing: Tokens.Space.s12) {
                            practiceCard(stats)
                            listRow(icon: "tray", title: Loc.t("Пойманные", "Caught"),
                                    subtitle: Loc.t("Сохранённые и распознанные фразы", "Saved and caught phrases"),
                                    count: stats.caught, id: "study.caught") { showCaught = true }
                            listRow(icon: "rectangle.stack", title: Loc.t("Во флеш-картах", "In flashcards"),
                                    subtitle: Loc.t("Фразы, которые вы учите", "The phrases you're learning"),
                                    count: stats.inStudy, id: "study.studying") { showStudying = true }
                            if stats.distribution.total > 0 || stats.reviewsByDay.contains(where: { $0.count > 0 }) {
                                ReviewsCard(days: stats.reviewsByDay)
                                DistributionCard(distribution: stats.distribution)
                            }
                        }
                        .padding(.horizontal, Tokens.Space.s16)
                        .padding(.vertical, Tokens.Space.s8)
                        // A sideways swipe over a button must not press it (Study has no tab to its left).
                        .environment(\.swipeSafeButtons, true)
                    }
                } else {
                    LoadingView(Loc.t("Загружаю…", "Loading…"))
                }
            }
            .navigationTitle(Loc.t("Изучаю", "Study"))
            .settingsTrigger()
            .navigationDestination(isPresented: $showCaught) { StudyListView(model: caught) }
            .navigationDestination(isPresented: $showStudying) { StudyListView(model: studying) }
            // Every return here (launch, tab switch, back from a list, a closed session) re-counts.
            .onAppear { Task { await model.load() } }
            // The goal is set in Settings (a sheet over this screen): re-count when it closes.
            .onChange(of: ui.showSettings) { _, shown in if !shown { Task { await model.load() } } }
            .fullScreenCover(item: $model.session, onDismiss: { model.endPractice() }) { session in
                FlashcardSessionView(model: session) { model.session = nil }
            }
        }
    }

    // MARK: Practice

    private func practiceCard(_ stats: StudyStats) -> some View {
        let locked = !subscription.tier.canUseFlashcards
        let plan = stats.today
        return VStack(alignment: .leading, spacing: Tokens.Space.s16) {
            HStack(alignment: .firstTextBaseline) {
                Text(Loc.t("Флеш-карты", "Flashcards"))
                    .textStyle(Tokens.Text.headline)
                    .foregroundStyle(Tokens.Content.primary)
                Spacer()
                Text(Loc.t("Цель: \(plan.goal) в день", "Goal: \(plan.goal) a day", "Objectif : \(plan.goal) par jour",
                           "Objetivo: \(plan.goal) al día", "Ziel: \(plan.goal) pro Tag", "Obiettivo: \(plan.goal) al giorno"))
                    .textStyle(Tokens.Text.footnote)
                    .foregroundStyle(Tokens.Content.secondary)
            }
            if stats.inStudy > 0 {
                GoalProgress(plan: plan)
            }
            HStack(alignment: .top, spacing: Tokens.Space.s8) {
                StatTile(value: plan.due, label: Loc.t("к повторению", "to review"))
                StatTile(value: plan.nextSet.new, label: Loc.t("новых в наборе", "new in the set"))
                StatTile(value: stats.inStudy, label: Loc.t("фраз в обучении", "phrases in study"))
            }
            if stats.inStudy == 0 {
                Text(Loc.t("Перенесите фразы из «Пойманных», чтобы начать учить.",
                           "Move phrases from Caught to start learning."))
                    .textStyle(Tokens.Text.subhead)
                    .foregroundStyle(Tokens.Content.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !plan.hasMore {
                Text(Loc.t("На сегодня всё — возвращайтесь завтра.", "All done for today — come back tomorrow."))
                    .textStyle(Tokens.Text.subhead)
                    .foregroundStyle(Tokens.Content.secondary)
            } else if plan.goalReached && plan.pending.total == 0 {
                Text(Loc.t("Цель на сегодня выполнена — можно позаниматься ещё.",
                           "Today's goal reached — you can keep going."))
                    .textStyle(Tokens.Text.subhead)
                    .foregroundStyle(Tokens.Content.secondary)
            }
            if stats.inStudy == 0 && !locked {
                EHButton(Loc.t("Открыть «Пойманные»", "Open Caught"), icon: "tray", kind: .tonal,
                         fillWidth: true, accessibilityID: "flashcards.openCaught") { showCaught = true }
            } else {
                // The day is one practice: Start, then Continue after a pause; past the goal, more.
                let more = plan.goalReached && plan.pending.total == 0 && !locked
                EHButton(more ? Loc.t("Ещё \(plan.goal)", "\(plan.goal) more", "\(plan.goal) de plus", "\(plan.goal) más",
                                      "\(plan.goal) weitere", "Altre \(plan.goal)")
                              : plan.studied > 0 && !locked ? Loc.t("Продолжить", "Continue") : Loc.t("Начать", "Start"),
                         icon: locked ? "lock.fill" : nil, kind: .primary,
                         fillWidth: true, accessibilityID: "flashcards.start") {
                    if locked { ui.showPaywall = true } else { model.startPractice(extra: more) }
                }
                .disabled(!locked && !plan.hasMore)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    // MARK: Lists

    private func listRow(icon: String, title: String, subtitle: String, count: Int, id: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.s12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Tokens.Content.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .textStyle(Tokens.Text.headline)
                        .foregroundStyle(Tokens.Content.primary)
                    Text(subtitle)
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Content.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Tokens.Space.s8)
                Text("\(count)")
                    .textStyle(Tokens.Text.title3)
                    .foregroundStyle(Tokens.Content.primary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.Content.tertiary)
            }
            .padding(Tokens.Space.s16)
            .contentShape(Rectangle())
        }
        .buttonStyle(SwipeSafeButtonStyle())
        .glassPanel(cornerRadius: Tokens.Radius.card)
        .accessibilityLabel("\(title): \(count)")
        .accessibilityIdentifier(id)
    }
}

// MARK: - Pieces

/// A hero number with its label — the number is the chart.
private struct StatTile: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .textStyle(Tokens.Text.title1)
                .foregroundStyle(Tokens.Content.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Answers per day for the last week: today's count as the hero number, the week as thin bars (one
/// series, one tone; today emphasised), weekday initials under them.
private struct ReviewsCard: View {
    let days: [DailyReviews]
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            Text(Loc.t("Повторения", "Reviews"))
                .textStyle(Tokens.Text.headline)
                .foregroundStyle(Tokens.Content.primary)
            HStack(alignment: .bottom, spacing: Tokens.Space.s16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(days.last?.count ?? 0)")
                        .textStyle(Tokens.Text.largeTitle)
                        .foregroundStyle(Tokens.Content.primary)
                        .monospacedDigit()
                    Text(Loc.t("сегодня", "today"))
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Content.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                bars
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    private var bars: some View {
        let peak = max(days.map(\.count).max() ?? 0, 1)
        let height: CGFloat = 44
        return HStack(alignment: .bottom, spacing: Tokens.Space.s8) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let isToday = index == days.count - 1
                VStack(spacing: Tokens.Space.s4) {
                    ZStack(alignment: .bottom) {
                        // Baseline: a zero day still shows where its bar would stand.
                        Capsule().fill(Tokens.Hairline.default).frame(height: 1)
                        if day.count > 0 {
                            UnevenRoundedRectangle(topLeadingRadius: Tokens.Chart.barRadius,
                                                   topTrailingRadius: Tokens.Chart.barRadius)
                                .fill(isToday ? Tokens.Chart.barEmphasis : Tokens.Chart.bar)
                                .frame(height: max(3, height * CGFloat(day.count) / CGFloat(peak)))
                        }
                    }
                    .frame(width: 14, height: height, alignment: .bottom)
                    Text(weekday(day.day))
                        .textStyle(Tokens.Text.caption2)
                        .foregroundStyle(isToday ? Tokens.Content.primary : Tokens.Content.tertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Loc.t("Повторения за неделю", "Reviews this week"))
        .accessibilityValue(days.map { "\(weekdayName($0.day)): \($0.count)" }.joined(separator: ", "))
    }

    private func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("EEEEE")
        return f.string(from: date)
    }

    private func weekdayName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f.string(from: date)
    }
}

/// Cards by stage — new → learning → young → mature — as one part-to-whole bar (ordinal ramp, 2pt
/// gaps between segments) with a legend carrying every count.
private struct DistributionCard: View {
    let distribution: CardDistribution

    private var stages: [(label: String, count: Int, color: Color)] {
        [(Loc.t("Новые", "New"), distribution.new, Tokens.Chart.stage[0]),
         (Loc.t("Изучаются", "Learning"), distribution.learning, Tokens.Chart.stage[1]),
         (Loc.t("Молодые", "Young"), distribution.young, Tokens.Chart.stage[2]),
         (Loc.t("Зрелые", "Mature"), distribution.mature, Tokens.Chart.stage[3])]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            HStack(alignment: .firstTextBaseline) {
                Text(Loc.t("Карточки", "Cards"))
                    .textStyle(Tokens.Text.headline)
                    .foregroundStyle(Tokens.Content.primary)
                Spacer()
                Text("\(distribution.total)")
                    .textStyle(Tokens.Text.headline)
                    .foregroundStyle(Tokens.Content.secondary)
                    .monospacedDigit()
            }
            bar
            legend
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    private var bar: some View {
        GeometryReader { geo in
            let shown = stages.filter { $0.count > 0 }
            let gaps = Tokens.Chart.gap * CGFloat(max(shown.count - 1, 0))
            let width = max(geo.size.width - gaps, 0)
            HStack(spacing: Tokens.Chart.gap) {
                if shown.isEmpty {
                    Capsule().fill(Tokens.Fill.default)
                } else {
                    ForEach(shown, id: \.label) { stage in
                        Rectangle()
                            .fill(stage.color)
                            .frame(width: width * CGFloat(stage.count) / CGFloat(max(distribution.total, 1)))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Loc.t("Карточки по стадиям", "Cards by stage"))
        .accessibilityValue(stages.map { "\($0.label) \($0.count)" }.joined(separator: ", "))
    }

    /// One row when it fits (keeps the card short); two columns with large text.
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.s12) {
                ForEach(stages, id: \.label) { legendItem($0) }
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: Tokens.Space.s8) {
                ForEach(stages, id: \.label) { legendItem($0) }
            }
        }
    }

    private func legendItem(_ stage: (label: String, count: Int, color: Color)) -> some View {
        HStack(spacing: Tokens.Space.s4) {
            RoundedRectangle(cornerRadius: 2).fill(stage.color).frame(width: 10, height: 10)
            Text(stage.label)
                .textStyle(Tokens.Text.subhead)
                .foregroundStyle(Tokens.Content.secondary)
            Text("\(stage.count)")
                .textStyle(Tokens.Text.subhead)
                .foregroundStyle(Tokens.Content.primary)
                .monospacedDigit()
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
