//
//  CatchFromPhotosView.swift
//  EnglishHelper — Presentation
//
//  The progress sheet for Caught → "From photos": a progress bar over the picked photos, how many
//  cards were caught, Stop while it runs, Done at the end. The paywall is presented from here — a
//  second sheet can't open over this one from the root.
//

import SwiftUI
import Domain
import DesignSystem

struct CatchFromPhotosView: View {
    @State var model: CatchFromPhotosViewModel
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
                    ProgressView(value: model.phase == .preparing ? nil : model.progress.fraction)
                        .tint(Tokens.Content.primary)
                        .accessibilityIdentifier("catch.progress")
                    HStack {
                        Text(Loc.t("Фото: \(model.progress.processed) из \(model.progress.total)",
                                   "Photos: \(model.progress.processed) of \(model.progress.total)",
                                   "Photos : \(model.progress.processed) sur \(model.progress.total)",
                                   "Fotos: \(model.progress.processed) de \(model.progress.total)",
                                   "Fotos: \(model.progress.processed) von \(model.progress.total)",
                                   "Foto: \(model.progress.processed) di \(model.progress.total)"))
                        Spacer()
                        Text(Loc.t("Карточек: \(model.progress.added)", "Cards: \(model.progress.added)",
                                   "Cartes : \(model.progress.added)", "Tarjetas: \(model.progress.added)",
                                   "Karten: \(model.progress.added)", "Schede: \(model.progress.added)"))
                            .accessibilityIdentifier("catch.added")
                    }
                    .textStyle(Tokens.Text.subhead)
                    .foregroundStyle(Tokens.Content.secondary)
                    .monospacedDigit()
                }
                .padding(Tokens.Space.s16)
                .glassPanel(cornerRadius: Tokens.Radius.card)

                if model.progress.empty > 0 {
                    Text(Loc.t("Без карточек: \(model.progress.empty) — на фото нет выделенной фразы. Выделите маркером, подчеркните или обведите на странице то, что хотите учить.",
                               "No cards from \(model.progress.empty) — nothing featured or marked on them. Highlight, underline or circle on the page what you want to learn.",
                               "Aucune carte pour \(model.progress.empty) — rien n'y est mis en avant ni marqué. Surlignez, soulignez ou entourez sur la page ce que vous voulez apprendre.",
                               "Sin tarjetas de \(model.progress.empty) — no hay nada destacado ni marcado. Resalta, subraya o rodea en la página lo que quieras aprender.",
                               "Keine Karten aus \(model.progress.empty) — nichts hervorgehoben oder markiert. Markiere, unterstreiche oder umkreise auf der Seite, was du lernen willst.",
                               "Nessuna scheda da \(model.progress.empty) — niente in evidenza né segnato. Evidenzia, sottolinea o cerchia sulla pagina ciò che vuoi imparare."))
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Content.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("catch.empty")
                }
                if model.progress.failed > 0 {
                    Text(Loc.t("Не удалось обработать фото: \(model.progress.failed)",
                               "Photos that couldn't be read: \(model.progress.failed)",
                               "Photos illisibles : \(model.progress.failed)",
                               "Fotos que no se pudieron leer: \(model.progress.failed)",
                               "Nicht lesbare Fotos: \(model.progress.failed)",
                               "Foto non leggibili: \(model.progress.failed)"))
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Content.secondary)
                }
                if let error = model.errorMessage {
                    Text(error)
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Content.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
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
            .navigationTitle(Loc.t("Карточки из фото", "Cards from photos"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isRunning {
                        Button(Loc.t("Стоп", "Stop")) { model.cancel() }
                    } else {
                        Button(Loc.t("Готово", "Done")) { onClose() }
                            .accessibilityIdentifier("catch.done")
                    }
                }
            }
            .sheet(isPresented: $showPaywall) { PaywallView().environment(subscription) }
        }
        .interactiveDismissDisabled(isRunning)
        .presentationDetents([.medium])
    }

    private var isRunning: Bool { model.phase == .preparing || model.phase == .processing }

    private var icon: String {
        switch model.phase {
        case .preparing, .processing: "text.viewfinder"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch model.phase {
        case .preparing: Loc.t("Готовлю фото…", "Preparing photos…")
        case .processing: Loc.t("Распознаю слова и выражения…", "Finding words and expressions…")
        case .done:
            Loc.t("Готово: карточек в «Пойманных» — \(model.progress.added)",
                  "Done: \(model.progress.added) cards in Caught",
                  "Terminé : \(model.progress.added) cartes dans « Capturées »",
                  "Listo: \(model.progress.added) tarjetas en «Atrapadas»",
                  "Fertig: \(model.progress.added) Karten in „Eingefangen“",
                  "Fatto: \(model.progress.added) schede in «Catturate»")
        case .failed: Loc.t("Остановлено", "Stopped")
        }
    }
}
