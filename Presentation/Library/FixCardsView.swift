//
//  FixCardsView.swift
//  EnglishHelper — Presentation
//
//  The "Fix cards" sheet: reading the phrases (a progress line while it counts what needs fixing),
//  the choice of mode (only the incomplete ones / all / continue all / start over), then the run — a
//  two-part line: sent to the model in grey, answered in green catching up — with how many changed;
//  Stop while it works (the next run continues from there), Done at the end. The screen stays awake
//  while it works — a big deck takes a while. The paywall is presented from here (a second sheet
//  can't open from the root).
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
            ScrollView {
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

                    if model.isSurveying {
                        surveyPanel
                    } else if model.phase == .choosing {
                        choices
                    } else if model.progress.total > 0 || model.isRunning {
                        runPanel
                    }

                    if model.progress.failed > 0 {
                        note(Loc.t("Без ответа модели: \(model.progress.failed). Им исправлен только регистр букв; при следующем запуске каждая будет отправлена ещё раз, отдельно.",
                                   "No answer from the model: \(model.progress.failed). Only their letter case was fixed; the next run asks about each of them again, one by one.",
                                   "Sans réponse du modèle : \(model.progress.failed). Seule la casse a été corrigée ; la prochaine fois, chacune sera renvoyée séparément.",
                                   "Sin respuesta del modelo: \(model.progress.failed). Solo se corrigieron mayúsculas y minúsculas; la próxima vez se enviará cada una por separado.",
                                   "Ohne Antwort des Modells: \(model.progress.failed). Nur die Groß- und Kleinschreibung wurde korrigiert; beim nächsten Lauf wird jede einzeln erneut gesendet.",
                                   "Senza risposta del modello: \(model.progress.failed). Corrette solo maiuscole e minuscole; la prossima volta ognuna sarà inviata di nuovo, da sola."))
                            .accessibilityIdentifier("fix.unanswered")
                    }
                    if model.progress.givenUp > 0 {
                        note(Loc.t("Модель не смогла обработать даже по одной: \(model.progress.givenUp). Эти фразы оставлены как есть.",
                                   "The model couldn't handle these even one at a time: \(model.progress.givenUp). They're left as they are.",
                                   "Le modèle n'a pas pu les traiter, même une par une : \(model.progress.givenUp). Elles restent telles quelles.",
                                   "El modelo no pudo procesarlas ni de una en una: \(model.progress.givenUp). Se quedan como están.",
                                   "Das Modell konnte sie nicht einmal einzeln verarbeiten: \(model.progress.givenUp). Sie bleiben, wie sie sind.",
                                   "Il modello non è riuscito a elaborarle nemmeno una alla volta: \(model.progress.givenUp). Restano come sono."))
                            .accessibilityIdentifier("fix.givenUp")
                    }
                    if let error = model.errorMessage {
                        note(error)
                    }
                    if model.isRunning {
                        Text(Loc.t("Можно остановить в любой момент — в следующий раз исправление продолжится с этого места.",
                                   "You can stop at any time — next time it continues from here."))
                            .textStyle(Tokens.Text.footnote)
                            .foregroundStyle(Tokens.Content.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    if model.needsSubscription {
                        EHButton(Loc.t("Оформить подписку", "Subscribe"), kind: .primary, fillWidth: true) {
                            showPaywall = true
                        }
                    }
                }
                .padding(.horizontal, Tokens.Space.s20)
                .padding(.bottom, Tokens.Space.s16)
                .frame(maxWidth: .infinity)
            }
            .background(Tokens.Surface.background)
            .navigationTitle(Loc.t("Исправление карточек", "Fixing cards"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if model.isBusy {
                        Button(Loc.t("Стоп", "Stop")) { model.stop() }
                            .accessibilityIdentifier("fix.stop")
                    } else if model.phase == .choosing {
                        Button(Loc.t("Отмена", "Cancel")) { onClose() }
                            .accessibilityIdentifier("fix.cancel")
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
        .task { model.prepare() }
        // A big deck takes a while: keep the screen on while it works.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Reading the phrases

    private var surveyPanel: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            if model.survey.total == 0 {
                ActivityLine()                                           // reading the cards: total unknown yet
            } else {
                ProgressLine(done: model.survey.fraction)
            }
            Text(model.survey.total == 0
                 ? Loc.t("Читаю карточки…", "Reading the cards…", "Lecture des cartes…", "Leyendo las tarjetas…",
                         "Karten werden gelesen…", "Lettura delle carte…")
                 : Loc.t("Проверено фраз: \(model.survey.checked) из \(model.survey.total)",
                         "Phrases checked: \(model.survey.checked) of \(model.survey.total)",
                         "Expressions vérifiées : \(model.survey.checked) sur \(model.survey.total)",
                         "Frases revisadas: \(model.survey.checked) de \(model.survey.total)",
                         "Geprüfte Ausdrücke: \(model.survey.checked) von \(model.survey.total)",
                         "Frasi controllate: \(model.survey.checked) di \(model.survey.total)"))
                .textStyle(Tokens.Text.subhead)
                .foregroundStyle(Tokens.Content.secondary)
                .monospacedDigit()
        }
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fix.survey")
    }

    // MARK: The modes

    private var choices: some View {
        VStack(spacing: Tokens.Space.s12) {
            Text(Loc.t("Всё строчными буквами (кроме I), грамматика, «to» у глаголов и артикли у существительных, недостающие примеры, синонимы и пояснения. «Только неполные» — карточки без примера, синонимов или пояснения. Тексты карточек перезаписываются, но заполненное поле не стирается — можно сначала экспортировать карточки как резервную копию. Прогресс изучения не меняется.",
                       "All lower case (except I), grammar, \"to\" for verbs and articles for nouns, missing examples, synonyms and notes. \"Only incomplete\" takes the cards missing an example, synonyms or a note. The card texts are overwritten, but a filled-in field is never emptied — you may want to export the cards as a backup first. Learning progress stays as it is."))
                .textStyle(Tokens.Text.subhead)
                .foregroundStyle(Tokens.Content.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Tokens.Space.s4)
            let offersIncomplete = (model.incomplete?.total ?? 0) > 0
            if let incomplete = model.incomplete, offersIncomplete {
                // From where the last such run stopped; once it went through them all, from the start.
                let count = incomplete.left > 0 ? incomplete.left : incomplete.total
                EHButton(Loc.t("Только неполные (\(count))", "Only incomplete (\(count))",
                               "Seulement les incomplètes (\(count))", "Solo las incompletas (\(count))",
                               "Nur unvollständige (\(count))", "Solo le incomplete (\(count))"),
                         kind: .primary, fillWidth: true, accessibilityID: "fix.incomplete") {
                    model.run(.incomplete, restart: incomplete.left == 0)
                }
            }
            if let all = model.all {
                let kind: EHButton.Kind = offersIncomplete ? .tonal : .primary
                if all.left == all.total {
                    EHButton(Loc.t("Все карточки (\(all.total))", "All cards (\(all.total))",
                                   "Toutes les cartes (\(all.total))", "Todas las tarjetas (\(all.total))",
                                   "Alle Karten (\(all.total))", "Tutte le carte (\(all.total))"),
                             kind: kind, fillWidth: true, accessibilityID: "fix.all") {
                        model.run(.all, restart: false)
                    }
                } else {
                    if all.left > 0 {
                        EHButton(Loc.t("Продолжить все (осталось \(all.left))", "Continue all (\(all.left) left)",
                                       "Continuer toutes (\(all.left) restantes)", "Continuar todas (quedan \(all.left))",
                                       "Alle fortsetzen (noch \(all.left))", "Continua tutte (\(all.left) rimanenti)"),
                                 kind: kind, fillWidth: true, accessibilityID: "fix.continue") {
                            model.run(.all, restart: false)
                        }
                    }
                    EHButton(Loc.t("Начать заново (все \(all.total))", "Start over (all \(all.total))",
                                   "Recommencer (toutes les \(all.total))", "Empezar de nuevo (las \(all.total))",
                                   "Neu beginnen (alle \(all.total))", "Ricomincia (tutte le \(all.total))"),
                             kind: .tonal, fillWidth: true, accessibilityID: "fix.restart") {
                        model.run(.all, restart: true)
                    }
                }
            }
        }
    }

    // MARK: The run

    private var runPanel: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            ProgressLine(done: model.progress.fraction, pending: model.progress.sentFraction)
                .accessibilityIdentifier("fix.progress")
            ProgressLineLegend(pending: Loc.t("отправлено", "sent", "envoyées", "enviadas", "gesendet", "inviate"),
                               done: Loc.t("готово", "done", "terminées", "listas", "fertig", "fatte"))
            Text(Loc.t("Фраз: \(model.progress.processed) из \(model.progress.total)",
                       "Phrases: \(model.progress.processed) of \(model.progress.total)",
                       "Expressions : \(model.progress.processed) sur \(model.progress.total)",
                       "Frases: \(model.progress.processed) de \(model.progress.total)",
                       "Ausdrücke: \(model.progress.processed) von \(model.progress.total)",
                       "Frasi: \(model.progress.processed) di \(model.progress.total)"))
                .textStyle(Tokens.Text.subhead)
                .foregroundStyle(Tokens.Content.secondary)
                .monospacedDigit()
            // What came of them: changed, already fine, no answer (asked again next run or given up).
            VStack(spacing: Tokens.Space.s4) {
                statRow(Loc.t("Изменено", "Changed", "Modifiées", "Cambiadas", "Geändert", "Modificate"),
                        model.progress.changed, id: "fix.changed")
                statRow(Loc.t("Без изменений", "No changes needed", "Sans changement", "Sin cambios",
                              "Ohne Änderung", "Senza modifiche"),
                        model.progress.unchanged, id: "fix.unchanged")
                statRow(Loc.t("С ошибкой (без ответа модели)", "With an error (no answer)", "En erreur (sans réponse)",
                              "Con error (sin respuesta)", "Mit Fehler (keine Antwort)", "Con errore (senza risposta)"),
                        model.progress.failed + model.progress.givenUp, id: "fix.errors")
            }
            .padding(.top, Tokens.Space.s4)
        }
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    private func statRow(_ title: String, _ value: Int, id: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(Tokens.Content.secondary)
            Spacer(minLength: Tokens.Space.s8)
            Text("\(value)")
                .foregroundStyle(Tokens.Content.primary)
                .monospacedDigit()
        }
        .textStyle(Tokens.Text.subhead)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .textStyle(Tokens.Text.footnote)
            .foregroundStyle(Tokens.Content.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var icon: String {
        switch model.phase {
        case .surveying: "doc.text.magnifyingglass"
        case .choosing, .running: "wand.and.stars"
        case .done: "checkmark.circle"
        case .stopped: "pause.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch model.phase {
        case .surveying: Loc.t("Считаю, что исправить…", "Counting what to fix…")
        case .choosing: Loc.t("Что исправить?", "What to fix?")
        case .running: Loc.t("Исправляю карточки…", "Fixing the cards…")
        case .done: model.progress.total > 0 ? Loc.t("Готово", "Done")
                                             : Loc.t("Во флеш-картах пока нет фраз", "No phrases in flashcards yet")
        case .stopped: model.progress.total > 0
            ? Loc.t("Остановлено — продолжится с этого места", "Stopped — it continues from here next time")
            : Loc.t("Остановлено", "Stopped")
        case .failed: Loc.t("Остановлено", "Stopped")
        }
    }
}
