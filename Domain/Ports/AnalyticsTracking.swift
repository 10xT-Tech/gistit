//
//  AnalyticsTracking.swift
//  EnglishHelper — Domain (port)
//
//  Product analytics port. Use cases report FEATURE-level events through this abstraction; the
//  concrete backend (Amplitude) lives in the Data layer and is wired at the composition root.
//
//  PRIVACY: events are a CLOSED enum with no payload, so no user content (intents, translations,
//  photos) can ever leak into analytics — there is simply nowhere to put it.
//

/// The closed set of product events the app reports. Raw value = the signal name sent to the
/// analytics backend (product vocabulary, not backend-specific).
public enum AnalyticsEvent: String, CaseIterable, Sendable {
    /// "Say it": intent → 3 studied-language variants finished (cache hits included).
    case sayItCompleted          = "SayIt.completed"
    /// "Say it": the user explicitly asked for a fresh set of variants.
    case sayItRegenerated        = "SayIt.regenerated"
    /// "Say it": situation → useful-phrases set finished.
    case whatToSayCompleted      = "WhatToSay.completed"
    /// "Get it" Translate: faithful translation finished (cache hits included).
    case translateCompleted      = "Translate.completed"
    /// "Get it" Explain: nuance explanation finished.
    case explainCompleted        = "Explain.completed"
    /// "See it" Translate: photo → translated blocks finished.
    case photoTranslateCompleted = "Photo.translateCompleted"
    /// "See it" Explain: photo scene explanation finished.
    case photoExplainCompleted   = "Photo.explainCompleted"
    /// "Get it" Online: a live listening session finished with some recognized speech.
    case liveTranslationCompleted = "Live.translationCompleted"
    /// A NEW expression was enriched and stored in the study list (de-dup returns don't count).
    case expressionSaved         = "Library.expressionSaved"
    /// The study list was exported as a deck file (AlgoApp or Anki).
    case deckExported            = "Library.deckExported"
}

/// Port for reporting `AnalyticsEvent`s. Implementations must be fire-and-forget and non-blocking
/// (a use case must never slow down or fail because of analytics), hence the synchronous,
/// non-throwing signature.
public protocol AnalyticsTracking: Sendable {
    func track(_ event: AnalyticsEvent)
}
