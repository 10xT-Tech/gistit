//
//  AppContainer.swift
//  EnglishHelper — App (composition root / DI)
//
//  The ONLY place that knows about concrete adapters. Builds ports, wires them into use cases,
//  and hands use cases to Presentation. v1 swaps `bootMock()` adapters for live ones; nothing
//  else in the graph changes.
//

import Foundation
import SwiftData
import OSLog
import Domain
import Adapters
import Presentation

public final class AppContainer: Sendable {
    public let config: AppConfig
    /// True when the on-disk store could not be opened and the app is running on an in-memory store:
    /// real Claude still works, but study-list/history changes WON'T survive relaunch. Drives a banner.
    public let usingFallbackStore: Bool

    private static let log = Logger(subsystem: "com.englishhelper.app", category: "persistence")

    // Ports (adapters)
    public let llm: any LLMClient
    public let speechRecognizer: any SpeechRecognizing       // ru-RU (Out)
    public let speechRecognizerEN: any SpeechRecognizing     // en-US (In)
    public let speechSynthesizer: any SpeechSynthesizing
    public let textRecognizer: any TextRecognizing
    public let expressions: any ExpressionRepository
    public let history: any HistoryRepository
    public let exporter: any DeckExporting
    /// Product analytics port. Nil (mock/UI-test boots) disables tracking — use cases treat it as optional.
    public let analytics: (any AnalyticsTracking)?

    // Use cases (what Presentation consumes)
    public let howToSay: any HowToSayUseCase
    public let whatToSay: any WhatToSayUseCase
    public let photoTranslate: any PhotoTranslateUseCase
    public let photoExplain: any PhotoExplainUseCase
    public let enrich: any EnrichExpressionUseCase
    public let studyList: any StudyListUseCase
    public let requestHistory: any RequestHistoryUseCase
    public let exportDeck: any ExportDeckUseCase        // AlgoApp .xml
    public let exportAnkiDeck: any ExportDeckUseCase    // Anki .txt
    public let regenerateHowToSay: any RegenerateHowToSayUseCase
    public let saveExpression: any SaveExpressionUseCase
    public let voiceCapture: any VoiceCaptureUseCase
    public let voiceCaptureEN: any VoiceCaptureUseCase
    public let pronounce: any PlayPronunciationUseCase
    public let connectionHealth: any ConnectionHealthUseCase
    public let transcriptionHealth: any TranscriptionHealthUseCase   // Soniox status (Settings)
    public let liveTranslate: any LiveTranslateUseCase               // "Get it" Online mode
    /// Session-recording playback/cleanup (History). A port, not a use case: it's a thin media
    /// facility like `pronounce`, consumed by History's view models directly.
    public let recordings: any SessionRecordingsManaging
    public let understand: any UnderstandUseCase
    public let cacheAdmin: any TranslationCacheAdminUseCase   // translation-cache stats + clear (Settings)
    public let storageUsage: any StorageUsageUseCase          // disk usage of cache/history/audio (Settings)
    public let explainExpression: any ExplainExpressionUseCase
    /// The user's plan (App Store subscription). Drives the paywall; the backend enforces it.
    public let subscriptions: any SubscriptionManaging

    public init(
        config: AppConfig,
        usingFallbackStore: Bool = false,
        llm: any LLMClient,
        speechRecognizer: any SpeechRecognizing,
        speechRecognizerEN: any SpeechRecognizing,
        speechSynthesizer: any SpeechSynthesizing,
        textRecognizer: any TextRecognizing,
        expressions: any ExpressionRepository,
        history: any HistoryRepository,
        exporter: any DeckExporting,
        cache: (any TranslationCache)? = nil,
        storageReader: (any StorageUsageReading)? = nil,
        analytics: (any AnalyticsTracking)? = nil,
        transcriptionService: any TranscriptionServiceChecking = MockTranscriptionService(),
        liveTranslating: any LiveTranslating = MockLiveTranslating(),
        recordings: any SessionRecordingsManaging = MockSessionRecordings(),
        subscriptions: any SubscriptionManaging = UnlimitedAccess()
    ) {
        self.config = config
        self.usingFallbackStore = usingFallbackStore
        self.llm = llm
        self.speechRecognizer = speechRecognizer
        self.speechRecognizerEN = speechRecognizerEN
        self.speechSynthesizer = speechSynthesizer
        self.textRecognizer = textRecognizer
        self.expressions = expressions
        self.history = history
        self.exporter = exporter
        self.analytics = analytics
        self.subscriptions = subscriptions

        // Wire use cases onto the ports.
        // Fixed per-scenario routing (not user-selectable): Say it + Explain → standard (Sonnet,
        // quality); plain Translate → fast (Haiku, speed).
        self.howToSay = HowToSayInteractor(llm: llm, history: history, cache: cache,
                                           tier: { .standard },
                                           analytics: analytics)
        self.whatToSay = WhatToSayInteractor(llm: llm, history: history, cache: cache,
                                             tier: { .standard },
                                             analytics: analytics)
        self.photoTranslate = PhotoTranslateInteractor(llm: llm, history: history,
                                                       analytics: analytics)          // LLM vision (no local OCR)
        self.photoExplain = PhotoExplainInteractor(llm: llm, history: history,
                                                   analytics: analytics)              // "See it" Explain mode
        self.enrich = EnrichExpressionInteractor(llm: llm)
        self.studyList = StudyListInteractor(repository: expressions)
        self.requestHistory = RequestHistoryInteractor(history: history, recordings: recordings)
        self.exportDeck = ExportDeckInteractor(repository: expressions, exporter: exporter,
                                               analytics: analytics)
        // Anki exporter is pure (no deps), built here at the composition root.
        self.exportAnkiDeck = ExportDeckInteractor(repository: expressions, exporter: AnkiExporter(),
                                                   analytics: analytics)
        self.regenerateHowToSay = RegenerateHowToSayInteractor(llm: llm, history: history, cache: cache,
                                                               tier: { .standard },
                                                               analytics: analytics)
        self.saveExpression = SaveExpressionInteractor(
            enrich: EnrichExpressionInteractor(llm: llm), repository: expressions,
            analytics: analytics
        )
        self.voiceCapture = VoiceCaptureInteractor(recognizer: speechRecognizer)
        self.voiceCaptureEN = VoiceCaptureInteractor(recognizer: speechRecognizerEN)
        self.pronounce = PlayPronunciationInteractor(synthesizer: speechSynthesizer)
        self.connectionHealth = ConnectionHealthInteractor(llm: llm)
        self.transcriptionHealth = TranscriptionHealthInteractor(service: transcriptionService)
        self.liveTranslate = LiveTranslateInteractor(live: liveTranslating, history: history,
                                                     recordings: recordings, analytics: analytics)
        self.recordings = recordings
        self.understand = UnderstandInteractor(llm: llm, history: history, cache: cache,
                                               tier: { .fast },
                                               analytics: analytics)
        self.explainExpression = ExplainExpressionInteractor(llm: llm,
                                                             tier: { .standard },
                                                             analytics: analytics)
        self.cacheAdmin = TranslationCacheAdminInteractor(cache: cache)
        self.storageUsage = StorageUsageInteractor(reader: storageReader)
    }

    /// v1: the whole graph on LIVE adapters. Swapping any engine is exactly ONE line below
    /// (see README "Swapping an engine"). The Domain/Presentation never learn which one is wired.
    public static func bootLive(config: AppConfig = .load(),
                                isReachable: (@Sendable () -> Bool)? = nil,
                                analytics: (any AnalyticsTracking)? = nil) throws -> AppContainer {
        let (modelContainer, usingFallbackStore) = try makePersistentContainer()
        // Shared by the live translator (writes), History playback (reads), and the history
        // repository's pruning (deletes audio of pruned rows).
        let recordings = SessionRecordingsPlayer()
        // Credentials: our backend (production — no third-party key in the app) or, without
        // BACKEND_URL, the embedded development keys.
        // Subscription (App Store version only — see StoreKitSubscriptionService). Without a backend
        // the app talks to the services directly (development), so everything stays unlocked.
        let storeKit = config.backendURL.map { _ in StoreKitSubscriptionService(productIDs: [AppConfig.subscriptionProductID]) }
        let backend = config.backendURL.map { url in
            BackendSession(baseURL: url, devToken: config.backendDevToken,
                           proofs: { await storeKit?.entitlementProofs() ?? .none })
        }
        if let storeKit {
            Task {
                await storeKit.start()
                // A plan change (purchase, renewal, expiry, refund) re-opens the backend session so
                // the server re-reads the tier.
                for await _ in storeKit.tierUpdates() {
                    await backend?.refreshEntitlements()
                }
            }
        }
        let claudeAuth: any RequestAuthorizing = backend ?? DirectAPIKeyAuthorizer(apiKey: config.claudeAPIKey ?? "")
        let sonioxCredential: SonioxCredential = backend.map { .temporaryKeys(from: $0) }
            ?? .apiKey(config.sonioxAPIKey ?? "")
        let transcriptionService: any TranscriptionServiceChecking = backend.map { BackendTranscriptionHealth(backend: $0) }
            ?? SonioxClient(apiKey: config.sonioxAPIKey ?? "")
        return AppContainer(
            config: config,
            usingFallbackStore: usingFallbackStore,
            llm: ClaudeLLMClient(authorizer: claudeAuth,
                                 model: config.claudeModel,
                                 fastModel: config.claudeFastModel,
                                 baseURL: config.backendURL ?? config.claudeBaseURL,
                                 isReachable: isReachable),
            // "Say it": the microphone follows the user's chosen native language (resolved per capture).
            speechRecognizer: NativeSpeechRecognizer(localeProvider: {
                Locale(identifier: TargetLanguage.current.speechLocale)
            }),
            // "Get it" mic listens in the STUDIED language (you capture studied-language speech to understand it).
            speechRecognizerEN: NativeSpeechRecognizer(localeProvider: {
                Locale(identifier: StudiedLanguage.current.speechLocale)
            }),
            // All TTS speaks the STUDIED language (resolved per utterance). ← swap TTS engine here
            speechSynthesizer: NativeSpeechSynthesizer(localeProvider: { StudiedLanguage.current.speechLocale }),
            // NB: the photo flow currently uses Claude's vision (PhotoTranslateInteractor → LLM), so this
            // on-device OCR adapter is wired for the port contract / future use but NOT consumed today.
            textRecognizer: VisionTextRecognizer(),         // ← swap OCR engine here (when OCR is used)
            expressions: SwiftDataExpressionRepository(modelContainer: modelContainer),
            history: SwiftDataHistoryRepository(modelContainer: modelContainer, recordings: recordings),
            exporter: AlgoAppXMLExporter(),
            // Persistent translation cache: repeat text translations skip the model (Say it + Get-it Translate).
            cache: SwiftDataTranslationCache(modelContainer: modelContainer),
            // Disk usage shown in Settings (cache/history row contents + session-audio file sizes).
            storageReader: StorageUsageReader(modelContainer: modelContainer, recordingsDirectory: nil),
            // Live product analytics (AmplitudeTracker) — created by the entry point, which owns the
            // single SDK instance; nil (no API key / tests) → analytics is simply off, like the API key.
            analytics: analytics,
            // Soniox (online translation). No key and no backend → the client reports .notConfigured,
            // which Settings shows as a "no key" status — same graceful degradation as the Claude key.
            transcriptionService: transcriptionService,
            liveTranslating: SonioxLiveTranslator(credential: sonioxCredential,
                                                  model: config.sonioxModel),   // ← swap live engine here
            recordings: recordings,
            subscriptions: storeKit ?? UnlimitedAccess()
        )
    }

    /// Open the on-disk SwiftData store, applying `AppMigrationPlan`. If the store can't be opened
    /// (corruption, or a schema change with no migration stage), DON'T silently downgrade to canned
    /// mocks — log it and fall back to an IN-MEMORY store so the app stays on real adapters (real
    /// Claude, real in-session save/history). The returned flag drives a visible "changes won't be
    /// saved" banner, so the user is never quietly losing data. The on-disk file is left untouched so
    /// a future build with a proper migration can still recover it. Throws only if even an in-memory
    /// store can't be created.
    private static func makePersistentContainer() throws -> (ModelContainer, fallback: Bool) {
        let schema = PersistenceSchema.current
        do {
            let onDisk = ModelConfiguration(schema: schema)
            let container = try ModelContainer(for: schema, migrationPlan: AppMigrationPlan.self, configurations: onDisk)
            return (container, false)
        } catch {
            log.error("On-disk store failed to open: \(String(describing: error), privacy: .public). Falling back to in-memory storage — changes this session will NOT persist.")
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return (try ModelContainer(for: schema, configurations: memory), true)
        }
    }

    /// UI tests (`-uiTestStubs` launch flag): the whole graph on deterministic STUB adapters whose
    /// latency makes any spurious re-request VISIBLE as the processing state, plus in-memory
    /// repositories — History then shows exactly one row per real LLM request, so a hidden
    /// regeneration can't slip past a test. No network, no permissions, no translation cache.
    public static func bootUITestStubs(config: AppConfig = .load()) -> AppContainer {
        AppContainer(
            config: config,
            llm: StubLLMClient(latency: .milliseconds(800)),
            speechRecognizer: StubSpeechRecognizing(),
            speechRecognizerEN: StubSpeechRecognizing(),
            speechSynthesizer: StubSpeechSynthesizing(),
            textRecognizer: StubTextRecognizing(),
            expressions: MockExpressionRepository(),
            history: MockHistoryRepository(),
            exporter: MockDeckExporting()
        )
    }

    /// Previews / tests / offline fallback: the whole graph on mocks. No network, no permissions.
    public static func bootMock(config: AppConfig = .load()) -> AppContainer {
        AppContainer(
            config: config,
            llm: MockLLMClient(),
            speechRecognizer: MockSpeechRecognizing(),
            speechRecognizerEN: MockSpeechRecognizing(),
            speechSynthesizer: MockSpeechSynthesizing(),
            textRecognizer: MockTextRecognizing(),
            expressions: MockExpressionRepository(),
            history: MockHistoryRepository(),
            exporter: MockDeckExporting()
        )
    }

    @MainActor
    public func makeVoiceViewModel() -> VoiceViewModel {
        VoiceViewModel(
            howToSay: howToSay,
            regenerateHowToSay: regenerateHowToSay,
            whatToSay: whatToSay,
            voiceCapture: voiceCapture,
            pronounce: pronounce,
            saveExpression: saveExpression,
            studyList: studyList,
            isConfigured: config.isClaudeConfigured
        )
    }

    @MainActor
    public func makeInViewModel() -> InViewModel {
        InViewModel(
            understand: understand,
            explain: explainExpression,
            voiceCapture: voiceCaptureEN,
            liveTranslate: liveTranslate,
            pronounce: pronounce,
            saveExpression: saveExpression,
            studyList: studyList,
            isConfigured: config.isClaudeConfigured,
            isLiveConfigured: config.isSonioxConfigured,
            longTask: LongTaskCoordinator(),
            // Lock Screen Live Activity for the running online session (pause/stop from the banner).
            liveActivity: LiveTranslationActivityController()
        )
    }

    @MainActor
    public func makePhotoTranslateViewModel() -> PhotoTranslateViewModel {
        PhotoTranslateViewModel(
            photoTranslate: photoTranslate,
            photoExplain: photoExplain,
            pronounce: pronounce,
            saveExpression: saveExpression,
            studyList: studyList,
            isConfigured: config.isClaudeConfigured,
            longTask: LongTaskCoordinator()
        )
    }

    @MainActor
    public func makeStudyListViewModel() -> StudyListViewModel {
        StudyListViewModel(
            studyList: studyList,
            saveExpression: saveExpression,
            exportAlgoApp: exportDeck,
            exportAnki: exportAnkiDeck,
            pronounce: pronounce,
            isConfigured: config.isClaudeConfigured
        )
    }

    @MainActor
    public func makeHistoryViewModel() -> HistoryViewModel {
        HistoryViewModel(
            history: requestHistory, saveExpression: saveExpression,
            studyList: studyList, pronounce: pronounce, recordings: recordings
        )
    }

    /// Reconcile the recordings store against history: a crash mid-session, the in-memory fallback
    /// store, or a failed save can all leave audio files no history row references. Called once per
    /// launch (best-effort). History is capped at `SwiftDataHistoryRepository.maxEntries`, so one
    /// `recent` read sees every live row.
    public func sweepOrphanedRecordings() async {
        guard let entries = try? await requestHistory.recent(limit: SwiftDataHistoryRepository.maxEntries) else { return }
        let referenced = Set(entries.compactMap { entry -> String? in
            guard case .liveTranslation(_, _, let fileName?, _) = entry.result else { return nil }
            return fileName
        })
        await recordings.sweep(keeping: referenced)
    }

    @MainActor
    public func makeSubscriptionState() -> SubscriptionState {
        SubscriptionState(service: subscriptions, productID: AppConfig.subscriptionProductID,
                          privacyPolicyURL: AppConfig.privacyPolicyURL, termsOfUseURL: AppConfig.termsOfUseURL)
    }

    @MainActor
    public func makeSettingsViewModel() -> SettingsViewModel {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return SettingsViewModel(
            connectionHealth: connectionHealth,
            transcriptionHealth: transcriptionHealth,
            cacheAdmin: cacheAdmin,
            storageUsage: storageUsage,
            appVersion: version
        )
    }
}
