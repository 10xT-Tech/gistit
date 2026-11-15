//
//  CardFix.swift
//  EnglishHelper — Presentation
//
//  The wand on a flashcard — in practice (once the answer is shown) and in the In-flashcards card
//  view: send THIS card through the model again, to fix it and fill in what's missing (an example,
//  synonyms, the note), when the user sees it isn't complete. One model, one button and one status
//  line for both places:
//  - `CardFixModel` runs the request for one card at a time and holds what came of it — fixing,
//    updated, nothing to change, or why it failed (with the subscription offered when it was the free
//    plan's limit: the request is metered like a Fix cards batch) — tied to that card, so the status
//    never shows on another one;
//  - `FixCardButton` is the wand (a spinner while it runs);
//  - `CardFixStatusLine` says what happened, under the card's texts.
//  The learning progress is never touched; the caller puts the returned texts on screen.
//

import SwiftUI
import Domain
import DesignSystem

@MainActor
@Observable
public final class CardFixModel {
    public enum Status: Equatable {
        case fixing
        /// The model changed the card.
        case updated
        /// The model answered and found nothing to change.
        case unchanged
        case failed(message: String, needsSubscription: Bool)
    }

    /// The card the status is about.
    public private(set) var subjectID: UUID?
    public private(set) var status: Status?

    private let fixCards: any FixCardsUseCase
    private let studiedLanguage: () -> String
    private let nativeLanguage: () -> String

    public init(fixCards: any FixCardsUseCase,
                studiedLanguage: @escaping () -> String = { StudiedLanguage.current.promptName },
                nativeLanguage: @escaping () -> String = { TargetLanguage.current.promptName }) {
        self.fixCards = fixCards
        self.studiedLanguage = studiedLanguage
        self.nativeLanguage = nativeLanguage
    }

    /// What's known about fixing THIS card — nil for any other.
    public func status(for expression: Domain.Expression) -> Status? {
        subjectID == expression.id ? status : nil
    }

    public var isFixing: Bool { status == .fixing }

    /// The wand was tapped: the status turns to "fixing" AT ONCE (so the button can't be tapped
    /// twice), the request runs behind it, and `adopt` gets the card as stored — changed or not —
    /// when it succeeds. Nothing happens while another request is still running.
    public func start(_ expression: Domain.Expression, then adopt: @escaping @MainActor (Domain.Expression) -> Void) {
        guard begin(expression) else { return }
        Task { [weak self] in
            guard let fixed = await self?.run(expression) else { return }
            adopt(fixed)
        }
    }

    /// The same, awaited: the card as stored, or nil when the request failed (the status says why) or
    /// another one is still running.
    @discardableResult
    public func fix(_ expression: Domain.Expression) async -> Domain.Expression? {
        guard begin(expression) else { return nil }
        return await run(expression)
    }

    private func begin(_ expression: Domain.Expression) -> Bool {
        guard !isFixing else { return false }
        subjectID = expression.id
        status = .fixing
        return true
    }

    private func run(_ expression: Domain.Expression) async -> Domain.Expression? {
        do {
            let fixed = try await fixCards.fix(expression, studiedLanguage: studiedLanguage(),
                                               nativeLanguage: nativeLanguage())
            status = fixed == expression ? .unchanged : .updated
            return fixed
        } catch {
            let presented = presentableError(error)
            status = .failed(message: presented.message, needsSubscription: presented.needsSubscription)
            return nil
        }
    }

    /// Another card is on screen (or the card view closed): the last result is no longer shown. A
    /// request still running keeps its place — its result just won't match the new card.
    public func clear() {
        guard !isFixing else { return }
        subjectID = nil
        status = nil
    }
}

/// The wand: fix this card with the model. A spinner while the request runs.
struct FixCardButton: View {
    let status: CardFixModel.Status?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if status == .fixing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Tokens.Content.secondary)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(status == .fixing)
        .accessibilityLabel(Loc.t("Исправить карточку", "Fix the card", "Corriger la carte", "Corregir la tarjeta",
                                  "Karte korrigieren", "Correggi la scheda"))
        .accessibilityHint(Loc.t("Модель проверит карточку и заполнит пустые поля",
                                 "The model checks the card and fills in what's missing"))
        .accessibilityIdentifier("card.fix")
    }
}

/// What came of fixing the card — under its texts. Nothing while there's nothing to say.
struct CardFixStatusLine: View {
    let status: CardFixModel.Status?
    /// The free plan's limit stopped it: open the paywall.
    let onSubscribe: () -> Void

    var body: some View {
        switch status {
        case nil:
            EmptyView()
        case .fixing:
            line("sparkles", Loc.t("Модель проверяет карточку…", "The model is checking the card…",
                                   "Le modèle vérifie la carte…", "El modelo revisa la tarjeta…",
                                   "Das Modell prüft die Karte…", "Il modello controlla la scheda…"),
                 tone: Tokens.Content.secondary)
        case .updated:
            line("checkmark.circle", Loc.t("Карточка обновлена", "The card is updated", "Carte mise à jour",
                                           "Tarjeta actualizada", "Karte aktualisiert", "Scheda aggiornata"),
                 tone: Tokens.Signal.success)
        case .unchanged:
            line("checkmark.circle", Loc.t("Карточка в порядке — менять нечего", "The card is fine — nothing to change",
                                           "La carte est correcte — rien à changer", "La tarjeta está bien: nada que cambiar",
                                           "Die Karte ist in Ordnung – nichts zu ändern", "La scheda è a posto: niente da cambiare"),
                 tone: Tokens.Content.secondary)
        case .failed(let message, let needsSubscription):
            VStack(alignment: .leading, spacing: Tokens.Space.s8) {
                line("exclamationmark.circle",
                     Loc.t("Не удалось исправить карточку.", "Couldn't fix the card.", "Impossible de corriger la carte.",
                           "No se pudo corregir la tarjeta.", "Die Karte konnte nicht korrigiert werden.",
                           "Impossibile correggere la scheda.") + " " + message,
                     tone: Tokens.Content.secondary)
                if needsSubscription {
                    EHButton(Loc.t("Оформить подписку", "Subscribe"), icon: "sparkles", kind: .tonal, fillWidth: true,
                             accessibilityID: "card.fix.subscribe", action: onSubscribe)
                }
            }
        }
    }

    private func line(_ icon: String, _ text: String, tone: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s8) {
            Image(systemName: icon)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textStyle(Tokens.Text.footnote)
        .foregroundStyle(tone)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card.fix.status")
    }
}
