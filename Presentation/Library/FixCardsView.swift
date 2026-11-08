//
//  FixCardsView.swift
//  EnglishHelper — Presentation
//
//  The progress sheet of "Fix cards": a bar over the phrases, how many changed, Stop while it runs
//  (the next run continues from there), Done at the end. The screen stays awake while it works — a
//  big deck takes a while. The paywall is presented from here (a second sheet can't open from the root).
//

import SwiftUI
import UIKit
import Domain
import DesignSystem

struct FixCardsView: View {
    @State var model: FixCardsViewModel
    let onClose: () -> Void
    @State private var showPaywall = false
    @Environment(SubscriptionState.self) private var subscription

    var body: some View {
        NavigationStack {
            VStack(spacing: Tokens.Space.s20) {
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Tokens.Content.primary)
                    .padding(.top, Tokens.Space.s24)
                    .accessibilityHidden(true)
                Text(title)
                    .textStyle(Tokens.Text.title3)
                    .foregroundStyle(Tokens.Content.primary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: Tokens.Space.s8) {
                    ProgressView(value: model.progress.fraction)
                        .tint(Tokens.Content.primary)
                        .accessibilityIdentifier("fix.progress")
                    HStack {
                        Text(Loc.t("Фраз: \(model.progress.processed) из \(model.progress.total)",
                                   "Phrases: \(model.progress.processed) of \(model.progress.total)",
                                   "Expressions : \(model.progress.processed) sur \(model.progress.total)",
                                   "Frases: \(model.progress.processed) de \(model.progress.total)",
                                   "Ausdrücke: \(model.progress.processed) von \(model.progress.total)",
                                   "Frasi: \(model.progress.processed) di \(model.progress.total)"))
                        Spacer()
                        Text(Loc.t("Исправлено: \(model.progress.changed)", "Fixed: \(model.progress.changed)",
                                   "Corrigées : \(model.progress.changed)", "Corregidas: \(model.progress.changed)",
                                   "Korrigiert: \(model.progress.changed)", "Corrette: \(model.progress.changed)"))
                            .accessibilityIdentifier("fix.changed")
                    }
                    .textStyle(Tokens.Text.subhead)
                    .foregroundStyle(Tokens.Content.secondary)
                    .monospacedDigit()
                }
                .padding(Tokens.Space.s16)
                .glassPanel(cornerRadius: Tokens.Radius.card)

                if model.progress.failed > 0 {
                    Text(Loc.t("Не удалось обработать: \(model.progress.failed) — им исправлен только регистр букв.",
                               "Couldn't be processed: \(model.progress.failed) — only their letter case was fixed.",
                               "Non traitées : \(model.progress.failed) — seule la casse a été corrigée.",
                               "No procesadas: \(model.progress.failed) — solo se corrigieron mayúsculas y minúsculas.",
                               "Nicht verarbeitet: \(model.progress.failed) — nur die Groß- und Kleinschreibung wurde korrigiert.",
                               "Non elaborate: \(model.progress.failed) — corrette solo maiuscole e minuscole."))
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Content.secondary)
                        .multilineTextAlignment(.center)
                }
                if let error = model.errorMessage {
                    Text(error)
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Content.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.isRunning {
                    Text(Loc.t("Можно остановить в любой момент — в следующий раз исправление продолжится с этого места.",
                               "You can stop at any time — next time it continues from here."))
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Content.tertiary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                if model.needsSubscription {
                    EHButton(Loc.t("Оформить подписку", "Subscribe"), kind: .primary, fillWidth: true) {
                        showPaywall = true
                    }
                }
            }
            .padding(.horizontal, Tokens.Space.s20)
            .padding(.bottom, Tokens.Space.s16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.Surface.background)
            .navigationTitle(Loc.t("Исправление карточек", "Fixing cards"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if model.isRunning {
                        Button(Loc.t("Стоп", "Stop")) { model.stop() }
                            .accessibilityIdentifier("fix.stop")
                    } else {
                        Button(Loc.t("Готово", "Done")) { onClose() }
                            .accessibilityIdentifier("fix.done")
                    }
                }
            }
            .sheet(isPresented: $showPaywall) { PaywallView().environment(subscription) }
        }
        .interactiveDismissDisabled(model.isRunning)
        .presentationDetents([.medium, .large])
        // A big deck takes a while: keep the screen on while it works.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var icon: String {
        switch model.phase {
        case .running: "wand.and.stars"
        case .done: "checkmark.circle"
        case .stopped: "pause.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch model.phase {
        case .running: Loc.t("Исправляю карточки…", "Fixing the cards…")
        case .done: Loc.t("Готово", "Done")
        case .stopped: Loc.t("Остановлено — продолжится с этого места", "Stopped — it continues from here next time")
        case .failed: Loc.t("Остановлено", "Stopped")
        }
    }
}
