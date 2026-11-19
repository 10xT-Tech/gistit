//
//  CatchFromPhotosView.swift
//  EnglishHelper — Presentation
//
//  The progress sheet for Caught → "From photos": a progress line over the picked photos (green done,
//  grey the photo being read), how many cards were caught, Stop while it runs, Done at the end — a
//  green check, the done chime and haptic (not after Stop). The paywall is presented from here — a
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
                    .foregroundStyle(model.phase == .done ? Tokens.Signal.success : Tokens.Content.primary)
                    .padding(.top, Tokens.Space.s24)
                    .accessibilityHidden(true)
                Text(title)
                    .textStyle(Tokens.Text.title3)
                    .foregroundStyle(Tokens.Content.primary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: Tokens.Space.s8) {
                    Group {
                        if model.phase == .preparing {
                            ActivityLine()
                        } else {
                            ProgressLine(done: model.progress.fraction, pending: reading)
                        }
                    }
                    .accessibilityRepresentation {
                        ProgressView(value: model.phase == .preparing ? nil : model.progress.fraction)
                    }
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
                if !model.progress.inFlashcards.isEmpty {
                    note(inFlashcardsNote)
                        .accessibilityIdentifier("catch.inFlashcards")
                }
                if !model.progress.alreadyInCaught.isEmpty {
                    note(alreadyInCaughtNote)
                        .accessibilityIdentifier("catch.alreadySaved")
                }
                if model.unloaded > 0 {
                    note(Loc.t("Не загрузилось из галереи: \(model.unloaded). Если фото хранится в iCloud, откройте его в «Фото», чтобы оно скачалось, и попробуйте снова.",
                               "Couldn't load from the library: \(model.unloaded). If the photo is in iCloud, open it in Photos so it downloads, and try again."))
                        .accessibilityIdentifier("catch.unloaded")
                }
                if model.progress.failed > 0 {
                    VStack(spacing: Tokens.Space.s4) {
                        note(Loc.t("Не удалось обработать фото: \(model.progress.failed) — \(failureReason)",
                                   "Photos that couldn't be processed: \(model.progress.failed) — \(failureReason)"))
                        if let detail = failureDetail {
                            Text(detail)
                                .textStyle(Tokens.Text.caption)
                                .foregroundStyle(Tokens.Content.tertiary)
                                .multilineTextAlignment(.center)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityIdentifier("catch.failed")
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
        .doneChime(when: model.phase == .done && !model.wasStopped)
    }

    private var isRunning: Bool { model.phase == .preparing || model.phase == .processing }

    /// The photos done plus the one being read (grey) while it runs.
    private var reading: Double {
        let progress = model.progress
        guard model.phase == .processing, progress.total > 0, progress.processed < progress.total else { return 0 }
        return Double(progress.processed + 1) / Double(progress.total)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .textStyle(Tokens.Text.footnote)
            .foregroundStyle(Tokens.Content.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Already in Caught, not added again: 2 — «in the heat of the moment», «come to terms with»".
    private var alreadyInCaughtNote: String {
        let (count, list) = Self.listed(model.progress.alreadyInCaught)
        return Loc.t("Уже есть в «Пойманных», повторно не добавлены: \(count) — \(list)",
                     "Already in Caught, not added again: \(count) — \(list)",
                     "Déjà dans « Capturées », pas ajoutées à nouveau : \(count) — \(list)",
                     "Ya están en «Atrapadas», no se añaden de nuevo: \(count) — \(list)",
                     "Schon in „Eingefangen“, nicht erneut hinzugefügt: \(count) — \(list)",
                     "Già in «Catturate», non aggiunte di nuovo: \(count) — \(list)")
    }

    /// "Already in flashcards — added, marked in the list: 1 — «discard»".
    private var inFlashcardsNote: String {
        let (count, list) = Self.listed(model.progress.inFlashcards)
        return Loc.t("Уже есть во флеш-картах — добавлены с пометкой в списке: \(count) — \(list)",
                     "Already in flashcards — added, marked in the list: \(count) — \(list)",
                     "Déjà dans les cartes — ajoutées, signalées dans la liste : \(count) — \(list)",
                     "Ya están en las tarjetas — añadidas, marcadas en la lista: \(count) — \(list)",
                     "Schon in den Lernkarten — hinzugefügt, in der Liste markiert: \(count) — \(list)",
                     "Già nelle schede — aggiunte, segnate nella lista: \(count) — \(list)")
    }

    /// The count and the first five phrases, quoted ("… and 3 more").
    private static func listed(_ phrases: [String]) -> (Int, String) {
        let shown = phrases.prefix(5).map { "«\($0)»" }.joined(separator: ", ")
        let more = phrases.count > 5 ? Loc.t(" и ещё \(phrases.count - 5)", " and \(phrases.count - 5) more") : ""
        return (phrases.count, shown + more)
    }

    /// Why the last failed photo failed, in words: a refusal, or the error as other screens put it.
    private var failureReason: String {
        guard let error = model.progress.lastError else {
            return Loc.t("попробуйте ещё раз.", "try again.")
        }
        if error == .invalidOutput(LLMError.declinedDetail) {
            return Loc.t("модель отказалась его обрабатывать. Обрежьте на скриншоте лишнее — чужие картинки, превью — и попробуйте снова.",
                         "the model declined it. Crop out what's around the text — other pictures, previews — and try again.")
        }
        return presentableError(error).message
    }

    /// The technical detail behind a request or answer failure — to pass on if it keeps happening.
    private var failureDetail: String? {
        switch model.progress.lastError {
        case .requestFailed(let detail)?, .requestRejected(let detail)?: detail
        case .invalidOutput(let detail)? where detail != LLMError.declinedDetail: detail
        default: nil
        }
    }

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
