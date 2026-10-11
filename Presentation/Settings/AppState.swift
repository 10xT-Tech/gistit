//
//  AppState.swift
//  EnglishHelper — Presentation
//
//  App-wide UI state shared above the tabs: theme preference (persisted) and the Settings sheet flag.
//

import SwiftUI
import Domain
import DesignSystem

/// Preferred tone/register for generated phrases ("Как сказать" / "Текст").
public enum ToneOfVoice: String, CaseIterable, Sendable {
    case formal, casual, slang
    public var title: String {
        switch self {
        case .formal: Loc.t("Формальный и вежливый", "Formal and polite")
        case .casual: Loc.t("Разговорно-бытовой", "Everyday conversational")
        case .slang: Loc.t("Неформальный, сленговый", "Casual, slangy")
        }
    }
    /// Compact label for the on-screen tone selector (the full `title` is too long for a segment).
    public var shortTitle: String {
        switch self {
        case .formal: Loc.t("Вежливый", "Polite")
        case .casual: Loc.t("Обычный", "Casual")
        case .slang: Loc.t("Сленг", "Slang")
        }
    }
    public var register: Register {
        switch self {
        case .formal: .formal
        case .casual: .casual
        case .slang: .slang
        }
    }
    /// Read the persisted preference (shared key, also read by the view models at generation time).
    public static var current: ToneOfVoice {
        ToneOfVoice(rawValue: Prefs.store.string(forKey: storageKey) ?? "") ?? .casual
    }
    static let storageKey = "toneOfVoice"
}

public enum ThemePreference: String, CaseIterable, Sendable {
    case system, light, dark
    public var title: String {
        switch self {
        case .system: Loc.t("Система", "System")
        case .light: Loc.t("Светлая", "Light")
        case .dark: Loc.t("Тёмная", "Dark")
        }
    }
}

@MainActor
@Observable
public final class ThemeStore {
    public var preference: ThemePreference {
        didSet { UserDefaults.standard.set(preference.rawValue, forKey: Self.key) }
    }

    private static let key = "themePreference"

    public init() {
        let raw = UserDefaults.standard.string(forKey: Self.key)
        preference = raw.flatMap(ThemePreference.init(rawValue:)) ?? .system
    }

    public var colorScheme: ColorScheme? {
        switch preference {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// A request to open the "Понять"/Get it screen in Explain mode for a specific phrase. Used to route
/// the "Explain" action from See it / History / Say it straight to the real Get it screen (no extra
/// sheet). The phrase is explained in its OWN right — never in a source-photo's context.
public struct ExplainRequest: Equatable, Sendable {
    public let text: String
    /// Sibling phrasings to contrast against — set when routing a per-variant "why this one?" from Say it.
    public let alternatives: [String]
    public init(text: String, alternatives: [String] = []) {
        self.text = text
        self.alternatives = alternatives
    }
}

/// A shared item from the iOS Share sheet, already mapped to its target scenario. The App bridges
/// `SharedInbox`'s payload to this Presentation-visible type; RootView routes it.
public enum SharedRoute: Equatable, Sendable {
    case explainText(String)   // → Get it / Explain
    case explainImage(Data)    // → See it / Explain
}

@MainActor
@Observable
public final class AppUIState {
    public var showSettings = false
    /// The subscription offer (from a free-plan limit, Online mode, or Settings).
    public var showPaywall = false
    /// Set to route to Get it (Explain mode) with this phrase; RootView consumes it and clears it.
    public var pendingExplain: ExplainRequest?
    public init() {}
}

/// First-launch onboarding gate. `isComplete` is false until the user picks their languages on the
/// welcome screen; persisted so onboarding shows exactly once.
@MainActor
@Observable
public final class OnboardingStore {
    public var isComplete: Bool {
        didSet { UserDefaults.standard.set(isComplete, forKey: Self.key) }
    }
    private static let key = "didCompleteOnboarding"
    public init() { isComplete = UserDefaults.standard.bool(forKey: Self.key) }
    public func complete() { isComplete = true }
}

// MARK: - Interface language (RU / EN / FR / ES / DE / IT, default: system)

public enum AppLanguage: String, CaseIterable, Sendable {
    case ru, en, fr, es, de, it
    /// Short code shown in the on-screen picker (RU / EN / FR / ES / DE / IT).
    public var abbreviation: String { rawValue.uppercased() }

    static let storageKey = AppLocale.storageKey

    /// The language actually used: the stored choice, else the system default among the supported
    /// languages, else English. (Resolution lives in `AppLocale` so `DSLoc` agrees with us.)
    public static var effective: AppLanguage {
        AppLanguage(rawValue: AppLocale.currentCode()) ?? .en
    }
}

@MainActor
@Observable
public final class LanguageStore {
    public var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.storageKey) }
    }
    /// Starts from the effective language; nothing is persisted until the user actually picks one
    /// (a property's `didSet` doesn't fire for its initial value).
    public init() { language = AppLanguage.effective }
    /// Derived from the tracked `language` property (NOT a fresh UserDefaults read) so @Observable
    /// dependents re-evaluate when the interface language changes.
    public var locale: Locale { Locale(identifier: language.rawValue) }
}

/// Tiny runtime localizer. Forwards to the DesignSystem resolver + catalog so Presentation and
/// DesignSystem share one source of truth. Russian + English are inline at the call site; French +
/// Spanish are looked up by the English string (see `LocCatalog`).
public enum Loc {
    public static func t(_ ru: String, _ en: String) -> String { DSLoc.t(ru, en) }
    /// Explicit six-language variant — for interpolated strings (no static key to look up).
    public static func t(_ ru: String, _ en: String, _ fr: String, _ es: String, _ de: String, _ it: String) -> String {
        DSLoc.t(ru, en, fr, es, de, it)
    }
}

// MARK: - Native language for "In" translation/explanation (RU / EN / FR / ES / DE / IT, default: RU)

public enum TargetLanguage: String, CaseIterable, Sendable {
    case russian, english, french, spanish, german, italian
    public var title: String {
        switch self {
        case .russian: Loc.t("Русский", "Russian")
        case .english: Loc.t("Английский", "English")
        case .french: Loc.t("Французский", "French")
        case .spanish: Loc.t("Испанский", "Spanish")
        case .german: Loc.t("Немецкий", "German")
        case .italian: Loc.t("Итальянский", "Italian")
        }
    }
    /// Short code shown in the on-screen picker (RU / EN / FR / ES / DE / IT).
    public var abbreviation: String {
        switch self {
        case .russian: "RU"
        case .english: "EN"
        case .french: "FR"
        case .spanish: "ES"
        case .german: "DE"
        case .italian: "IT"
        }
    }
    /// Name used in the LLM prompt (translation target / explanation language / "say it" source).
    public var promptName: String {
        switch self {
        case .russian: "Russian"
        case .english: "English"
        case .french: "French"
        case .spanish: "Spanish"
        case .german: "German"
        case .italian: "Italian"
        }
    }
    /// BCP-47 locale for recognizing speech in this language (the "say it" microphone input).
    public var speechLocale: String {
        switch self {
        case .russian: "ru-RU"
        case .english: "en-US"
        case .french: "fr-FR"
        case .spanish: "es-ES"
        case .german: "de-DE"
        case .italian: "it-IT"
        }
    }
    /// ISO-639-1 code ("ru") — the online-translation service speaks language codes, not names.
    public var languageCode: String { String(speechLocale.prefix(2)) }
    static let storageKey = "targetLanguage"
    public static var current: TargetLanguage {
        TargetLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .russian
    }
}

@MainActor
@Observable
public final class TargetLanguageStore {
    public var language: TargetLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: TargetLanguage.storageKey) }
    }
    public init() { language = TargetLanguage.current }
}

// MARK: - Studied language (the language being LEARNED; RU/EN/FR/ES/DE/IT, default: English)
//
// The card headline + all TTS are in this language across see/say/get. Mirrors TargetLanguage but
// defaults to English (kept a distinct type so a "studied" read can never be confused with "native").

public enum StudiedLanguage: String, CaseIterable, Sendable {
    case russian, english, french, spanish, german, italian
    public var title: String {
        switch self {
        case .russian: Loc.t("Русский", "Russian")
        case .english: Loc.t("Английский", "English")
        case .french: Loc.t("Французский", "French")
        case .spanish: Loc.t("Испанский", "Spanish")
        case .german: Loc.t("Немецкий", "German")
        case .italian: Loc.t("Итальянский", "Italian")
        }
    }
    /// Short code shown in the on-screen picker (RU / EN / FR / ES / DE / IT).
    public var abbreviation: String {
        switch self {
        case .russian: "RU"
        case .english: "EN"
        case .french: "FR"
        case .spanish: "ES"
        case .german: "DE"
        case .italian: "IT"
        }
    }
    /// Name used in the LLM prompt (the studied target for translations / variants / explanations).
    public var promptName: String {
        switch self {
        case .russian: "Russian"
        case .english: "English"
        case .french: "French"
        case .spanish: "Spanish"
        case .german: "German"
        case .italian: "Italian"
        }
    }
    /// BCP-47 locale for TTS in this language, and for the "get it" microphone input.
    public var speechLocale: String {
        switch self {
        case .russian: "ru-RU"
        case .english: "en-US"
        case .french: "fr-FR"
        case .spanish: "es-ES"
        case .german: "de-DE"
        case .italian: "it-IT"
        }
    }
    /// ISO-639-1 code ("en") — the online-translation service speaks language codes, not names.
    public var languageCode: String { String(speechLocale.prefix(2)) }
    static let storageKey = "studiedLanguage"
    public static var current: StudiedLanguage {
        StudiedLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .english
    }
}

@MainActor
@Observable
public final class StudiedLanguageStore {
    public var language: StudiedLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: StudiedLanguage.storageKey) }
    }
    public init() { language = StudiedLanguage.current }
}
