//
//  PresentableError.swift
//  EnglishHelper — Presentation
//
//  Maps domain errors to a user-facing message + offline flag, shared by the request screens.
//

import Foundation
import Domain

struct PresentableError {
    let message: String
    let isOffline: Bool
    /// The free plan's limit stopped this request: offer the subscription instead of Retry.
    var needsSubscription = false
}

/// "Free plan: one request to the model every 5 minutes — shared by explanations, Say it, cards from
/// photos and completing cards" — with the wait when the backend reported it. Names everything the
/// limit covers: the message also shows when a MOVE from Caught stops at it.
func subscriptionLimitMessage(retryAfter: Int?) -> String {
    guard let seconds = retryAfter, seconds > 0 else {
        return Loc.t("Бесплатный план: один запрос к модели в 5 минут — общий для объяснений, «Сказать», карточек из фото и дозаполнения карточек. С подпиской — без ограничений.",
                     "Free plan: one request to the model every 5 minutes — shared by explanations, Say it, cards from photos and completing cards. Subscribe for unlimited.",
                     "Offre gratuite : une requête au modèle toutes les 5 minutes — partagée entre explications, « Dire », cartes depuis des photos et complétion des cartes. Abonnez-vous pour un accès illimité.",
                     "Plan gratuito: una solicitud al modelo cada 5 minutos, compartida entre explicaciones, «Decir», tarjetas desde fotos y completar tarjetas. Suscríbete para uso ilimitado.",
                     "Kostenloser Plan: eine Anfrage an das Modell alle 5 Minuten – gemeinsam für Erklärungen, „Sagen“, Karten aus Fotos und das Vervollständigen von Karten. Abonniere für unbegrenzte Nutzung.",
                     "Piano gratuito: una richiesta al modello ogni 5 minuti, condivisa tra spiegazioni, «Dire», schede da foto e completamento delle schede. Abbonati per un uso illimitato.")
    }
    let minutes = max(1, Int((Double(seconds) / 60).rounded(.up)))
    return Loc.t(
        "Бесплатный план: один запрос к модели в 5 минут — общий для объяснений, «Сказать», карточек из фото и дозаполнения карточек. Следующий — через \(minutes) мин. С подпиской — без ограничений.",
        "Free plan: one request to the model every 5 minutes — shared by explanations, Say it, cards from photos and completing cards. Next one in \(minutes) min. Subscribe for unlimited.",
        "Offre gratuite : une requête au modèle toutes les 5 minutes — partagée entre explications, « Dire », cartes depuis des photos et complétion des cartes. Prochaine dans \(minutes) min. Abonnez-vous pour un accès illimité.",
        "Plan gratuito: una solicitud al modelo cada 5 minutos, compartida entre explicaciones, «Decir», tarjetas desde fotos y completar tarjetas. La siguiente en \(minutes) min. Suscríbete para uso ilimitado.",
        "Kostenloser Plan: eine Anfrage an das Modell alle 5 Minuten – gemeinsam für Erklärungen, „Sagen“, Karten aus Fotos und das Vervollständigen von Karten. Nächste in \(minutes) Min. Abonniere für unbegrenzte Nutzung.",
        "Piano gratuito: una richiesta al modello ogni 5 minuti, condivisa tra spiegazioni, «Dire», schede da foto e completamento delle schede. La prossima tra \(minutes) min. Abbonati per un uso illimitato.")
}

/// "Today's request limit is used up — it resets at 03:00": the device's daily allowance on our backend.
func dailyLimitMessage(retryAfter: Int?, now: Date = Date()) -> String {
    let reset: Date = retryAfter.map { now.addingTimeInterval(TimeInterval($0)) } ?? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return utc.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) ?? now
    }()
    let time = reset.formatted(date: .omitted, time: .shortened)
    return Loc.t("Дневной лимит запросов исчерпан — он обновится в \(time).",
                 "Today's request limit is used up — it resets at \(time).",
                 "La limite de requêtes du jour est atteinte — elle se réinitialise à \(time).",
                 "Se agotó el límite de solicitudes de hoy — se renueva a las \(time).",
                 "Das heutige Anfragelimit ist aufgebraucht — es wird um \(time) zurückgesetzt.",
                 "Il limite di richieste di oggi è esaurito — si azzera alle \(time).")
}

func presentableError(_ error: Error) -> PresentableError {
    guard let llm = error as? LLMError else {
        return PresentableError(message: Loc.t("Что-то пошло не так. Попробуйте ещё раз.",
                                               "Something went wrong. Try again."), isOffline: false)
    }
    switch llm {
    case .notConfigured:
        return PresentableError(message: Loc.t("Нет ключа Claude API. Добавьте его, чтобы продолжить.",
                                               "No Claude API key. Add one to continue."), isOffline: true)
    case .overloaded:
        return PresentableError(message: Loc.t("Сервис перегружен, попробуйте позже.",
                                               "Service is overloaded — try later."), isOffline: false)
    case .offline:
        return PresentableError(message: Loc.t("Нет соединения. Проверьте интернет и попробуйте снова.",
                                               "No connection. Check the internet and try again."), isOffline: true)
    case .timedOut:
        return PresentableError(message: Loc.t("Сервис не ответил вовремя. Попробуйте ещё раз.",
                                               "The service didn't respond in time. Try again."), isOffline: false)
    case .responseTooLong:
        return PresentableError(message: Loc.t("Слишком много текста для одного запроса. Попробуйте часть поменьше.",
                                               "Too much text to handle at once. Try a smaller part."), isOffline: false)
    case .invalidOutput:
        return PresentableError(message: Loc.t("Не удалось разобрать ответ. Попробуйте ещё раз.",
                                               "Couldn't parse the response. Try again."), isOffline: false)
    case .cancelled:
        return PresentableError(message: Loc.t("Запрос отменён.", "Request cancelled."), isOffline: false)
    case .requestFailed:
        return PresentableError(message: Loc.t("Сервис недоступен. Попробуйте позже.",
                                               "Service unavailable. Try later."), isOffline: false)
    case .requestRejected:
        return PresentableError(message: Loc.t("Сервис не принял этот запрос. Попробуйте изменить его.",
                                               "The service didn't accept this request. Try changing it."),
                                isOffline: false)
    case .subscriptionRequired(let retryAfter):
        return PresentableError(message: subscriptionLimitMessage(retryAfter: retryAfter), isOffline: false,
                                needsSubscription: true)
    case .dailyLimitReached(let retryAfter):
        return PresentableError(message: dailyLimitMessage(retryAfter: retryAfter), isOffline: false)
    }
}
