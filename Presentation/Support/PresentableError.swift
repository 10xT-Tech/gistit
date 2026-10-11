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

/// "Free plan: one explanation / Say it request per 5 minutes" — with the wait when the backend reported it.
func subscriptionLimitMessage(retryAfter: Int?) -> String {
    guard let seconds = retryAfter, seconds > 0 else {
        return Loc.t("Бесплатный план: объяснения и «Сказать» — один запрос в 5 минут. С подпиской — без ограничений.",
                     "Free plan: one explanation or Say it request every 5 minutes. Subscribe for unlimited.")
    }
    let minutes = max(1, Int((Double(seconds) / 60).rounded(.up)))
    return Loc.t(
        "Бесплатный план: объяснения и «Сказать» — один запрос в 5 минут. Следующий — через \(minutes) мин. С подпиской — без ограничений.",
        "Free plan: one explanation or Say it request every 5 minutes. Next one in \(minutes) min. Subscribe for unlimited.",
        "Offre gratuite : une explication ou une requête « Dire » toutes les 5 minutes. Prochaine dans \(minutes) min. Abonnez-vous pour un accès illimité.",
        "Plan gratuito: una explicación o solicitud de «Decir» cada 5 minutos. La siguiente en \(minutes) min. Suscríbete para uso ilimitado.",
        "Kostenloser Plan: eine Erklärung oder „Sagen“-Anfrage alle 5 Minuten. Nächste in \(minutes) Min. Abonniere für unbegrenzte Nutzung.",
        "Piano gratuito: una spiegazione o richiesta «Dire» ogni 5 minuti. La prossima tra \(minutes) min. Abbonati per un uso illimitato.")
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
    case .subscriptionRequired(let retryAfter):
        return PresentableError(message: subscriptionLimitMessage(retryAfter: retryAfter), isOffline: false,
                                needsSubscription: true)
    }
}
