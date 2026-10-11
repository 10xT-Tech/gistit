//
//  AppConfig.swift
//  EnglishHelper — App
//
//  Reads service config from the app's Info.plist, which is populated at build time from
//  `Secrets.xcconfig` (gitignored). See `Secrets.example.xcconfig`.
//
//  Two modes:
//  - BACKEND_URL set → production: Claude goes through our backend proxy and Soniox gets temporary
//    keys from it (Backend/, gated by App Attest). No third-party key is in the app.
//  - otherwise → development: CLAUDE_API_KEY / SONIOX_API_KEY are used directly. Those keys ARE
//    extractable from a built app, so Release builds strip them (Config/Base.xcconfig).
//

import Foundation

public struct AppConfig: Sendable {
    public let claudeAPIKey: String?
    public let claudeModel: String       // standard tier (Sonnet) — used for everything but plain translate
    public let claudeFastModel: String   // fast tier (Haiku) — used for plain translation, for speed
    public let claudeBaseURL: URL
    /// Soniox (speech-to-text — online translation). Nil = feature unconfigured; Settings
    /// shows a "no key" status instead of failing.
    public let sonioxAPIKey: String?
    /// Soniox real-time model — overridable in Secrets.xcconfig like the Claude models.
    public let sonioxModel: String
    /// Amplitude API key of the "GistIt" project (NOT a secret — Amplitude's client keys are
    /// write-only ingestion ids). Lives in the xcconfig alongside the Claude key for one-place
    /// config; nil (absent) just disables analytics.
    public let amplitudeAPIKey: String?
    /// Sentry DSN (crash & error reporting). NOT a secret — a DSN only lets a client SEND events.
    /// nil (absent) just disables crash reporting.
    public let sentryDSN: String?
    /// Our backend (Backend/ — AWS Lambda Function URL). When set it replaces both API keys.
    public let backendURL: URL?
    /// DEBUG-only escape hatch for the Simulator, where App Attest doesn't exist. Never read in Release.
    public let backendDevToken: String?

    public static let defaultModel = "claude-sonnet-5-5"
    public static let defaultFastModel = "claude-haiku-5-5"
    public static let defaultSonioxModel = "stt-rt-v5"
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    /// The monthly subscription (App Store Connect → Subscriptions). Must match the backend's
    /// `ProProductIds` stack parameter.
    public static let subscriptionProductID = "tech.10xt.englishhelper.pro.monthly"
    /// Shown on the paywall, required by App Review for auto-renewable subscriptions.
    public static let privacyPolicyURL = URL(string: "https://gistit.10xt.tech/privacy")!
    public static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    public init(claudeAPIKey: String?, claudeModel: String,
                claudeFastModel: String = defaultFastModel, claudeBaseURL: URL,
                sonioxAPIKey: String? = nil,
                sonioxModel: String = defaultSonioxModel,
                amplitudeAPIKey: String? = nil,
                sentryDSN: String? = nil,
                backendURL: URL? = nil,
                backendDevToken: String? = nil) {
        self.claudeAPIKey = claudeAPIKey
        self.claudeModel = claudeModel
        self.claudeFastModel = claudeFastModel
        self.claudeBaseURL = claudeBaseURL
        self.sonioxAPIKey = sonioxAPIKey
        self.sonioxModel = sonioxModel
        self.amplitudeAPIKey = amplitudeAPIKey
        self.sentryDSN = sentryDSN
        self.backendURL = backendURL
        self.backendDevToken = backendDevToken
    }

    /// `true` when requests go through our backend instead of embedded keys.
    public var usesBackend: Bool { backendURL != nil }

    /// `true` when the live LLM adapter can run (backend, or a non-empty direct key).
    public var isClaudeConfigured: Bool { usesBackend || (claudeAPIKey?.isEmpty == false) }

    /// `true` when online translation can run (backend, or a non-empty direct key).
    public var isSonioxConfigured: Bool { usesBackend || (sonioxAPIKey?.isEmpty == false) }

    public static func load(bundle: Bundle = .main) -> AppConfig {
        let info = bundle.infoDictionary
        func string(_ key: String) -> String? {
            guard let value = info?[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func devToken() -> String? {
            #if DEBUG
            return string("BACKEND_DEV_TOKEN")
            #else
            return nil
            #endif
        }
        return AppConfig(
            claudeAPIKey: string("CLAUDE_API_KEY"),
            claudeModel: string("CLAUDE_MODEL") ?? defaultModel,
            claudeFastModel: string("CLAUDE_FAST_MODEL") ?? defaultFastModel,
            claudeBaseURL: string("CLAUDE_BASE_URL").flatMap(URL.init(string:)) ?? defaultBaseURL,
            sonioxAPIKey: string("SONIOX_API_KEY"),
            sonioxModel: string("SONIOX_MODEL") ?? defaultSonioxModel,
            amplitudeAPIKey: string("AMPLITUDE_API_KEY"),
            sentryDSN: string("SENTRY_DSN"),
            backendURL: string("BACKEND_URL").flatMap(URL.init(string:)),
            backendDevToken: devToken()
        )
    }
}
