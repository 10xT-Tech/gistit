//
//  InViewModel.swift
//  EnglishHelper — Presentation
//
//  "Get it": voice OR typed text in ANY language. Translate mode renders it in the STUDIED language
//  (card headline + TTS) plus a NATIVE translation; Explain mode renders the studied form plus an
//  explanation written in the native language. Faithful translation only (no compose/tone).
//  Consumes USE CASES only.
//

import Foundation
import Domain

@MainActor
@Observable
public final class InViewModel {
    public enum Phase: Equatable { case idle, listening, processing, result, failed }

    /// What this screen does with input: explain a phrase's nuance, translate it — or ONLINE:
    /// listen to surrounding speech and translate it live. Order here drives the on-screen segment
    /// order (Explain first); Explain is the default.
    public enum Mode: String, CaseIterable, Sendable {
        case explain, translate, online
        public var title: String {
            switch self {
            case .translate: Loc.t("Перевод", "Translate")
            case .explain: Loc.t("Объяснение", "Explain")
            case .online: Loc.t("Онлайн", "Online", "En direct", "En vivo", "Live", "Dal vivo")
            }
        }
        /// Last-used mode, persisted so the screen comes back the way the user left it.
        static let storageKey = "getItMode"
        static var current: Mode {
            Mode(rawValue: Prefs.store.string(forKey: storageKey) ?? "") ?? .explain
        }
    }

    // UI state
    public private(set) var phase: Phase = .idle
    /// Mutated only via `selectMode`/`routeMode`/`startExplain` so the re-run/reset logic isn't
    /// bypassed. Persisted ONLY by `selectMode` (an explicit tap on the on-screen selector) — a
    /// routed change (Explain from a card/History, Share Extension, widget deep link) is
    /// session-only, so it can never silently overwrite the user's saved preference.
    public private(set) var mode: Mode = Mode.current
    public var source: String = "" {                     // editable transcript / typed input
        // Clearing the field (the ✕ button or deleting everything) re-arms the Paste affordance —
        // re-check the clipboard so the action button can flip to Paste (or disable) immediately.
        didSet { if source.isEmpty && !oldValue.isEmpty { refreshClipboardState() } }
    }
    public private(set) var studied: String?             // input rendered in the studied language (headline + TTS)
    public private(set) var translations: [TranslationVariant] = []  // Translate mode: 1–5 translations + context
    public private(set) var explanation: ExpressionExplanation?   // Explain mode result (native)
    public private(set) var errorMessage: String?
    /// A SAVE failure shown independently of `phase` (the result stays on screen); `errorMessage`
    /// only renders in `.failed`.
    public private(set) var saveError: String?
    public private(set) var isOffline = false
    /// The free plan's limit stopped the request — the screen offers the subscription instead of Retry.
    public private(set) var needsSubscription = false
    public private(set) var isPlaying = false
    public private(set) var isSaved = false
    /// Last observed "clipboard holds text" state (refreshed on appear / foreground / field clear).
    /// Drives the action button's Paste mode; the metadata check never triggers the iOS paste banner.
    public private(set) var clipboardHasText = false
    public var showMicPriming = false {
        // The sheet can close WITHOUT confirm/cancelPriming (interactive swipe-down just flips the
        // binding) — any close must consume a pending routed/live auto-start, or a LATER
        // press-originated confirm would wrongly start a capture. confirmPriming reads both first.
        didSet {
            if !showMicPriming {
                routedStartPending = false
                liveStartPending = false
            }
        }
    }

    // Online (live translation) state — deliberately SEPARATE from `phase`: the text-mode state
    // machine (idle/listening/…) belongs to typed/push-to-talk input and must survive a trip to
    // the Online segment untouched.
    public private(set) var isLiveListening = false
    /// Graceful stop in flight (finals draining) — the button shows a brief "finishing" state.
    public private(set) var isLiveStopping = false
    /// Session muted (Pause button): recognition/recording stopped, connection warm, resume instant.
    public private(set) var isLivePaused = false
    /// Translation direction. FALSE (default) = studied → native; TRUE = native → studied.
    /// Session-scoped, not persisted: every app launch starts in the default direction.
    public private(set) var isLiveReversed = false
    public private(set) var liveText = LiveTranslationText.empty
    /// Mic input level 0…1 for the on-button sound diagram.
    public private(set) var liveLevel: Float = 0
    public private(set) var liveErrorMessage: String?

    private var savedExpressionID: UUID?
    /// The input the on-screen result was generated from — restored on leaving the screen so an
    /// edit the user never submitted can't sit above a result it doesn't match.
    private var generatedSource: String?
    /// The mode that produced the on-screen result. A round trip back to this same mode must not
    /// re-fire the request — the result is still valid.
    private var generatedMode: Mode?

    /// Finished result of a text mode, kept when the user switches modes: coming BACK shows it
    /// again instead of re-asking the model. Matched by the input that produced it — an answer is
    /// only ever re-generated on an EXPLICIT user action (the action button), never by navigation.
    private struct CachedModeResult {
        var studied: String?
        var translations: [TranslationVariant]
        var explanation: ExpressionExplanation?
        var generatedSource: String
        var isSaved: Bool
        var savedExpressionID: UUID?
    }
    private var modeResults: [Mode: CachedModeResult] = [:]
    /// Bumped on every new result so an in-flight save can tell "user un-saved" from "result was
    /// regenerated" and not silently delete a just-bookmarked expression.
    private var resultsGeneration = 0
    private var explainAlternatives: [String] = []   // sibling variants to contrast (Say it "why this?")
    private var explainAlternativesText: String?     // the source text those alternatives belong to

    // Dependencies (use cases)
    private let understand: any UnderstandUseCase        // faithful translate → studied + native
    private let explain: any ExplainExpressionUseCase
    private let voiceCapture: any VoiceCaptureUseCase    // studied-language ASR
    private let liveTranslate: any LiveTranslateUseCase  // Online mode: mic → live STT + translation
    private let pronounce: any PlayPronunciationUseCase
    private let saveExpression: any SaveExpressionUseCase
    private let studyList: any StudyListUseCase
    private let isConfigured: Bool
    private let isLiveConfigured: Bool                   // Soniox key present (Online mode can run)
    /// Keeps a slow explanation/translation alive briefly after backgrounding + notifies on completion.
    /// Nil in tests/previews (then it's a transparent pass-through).
    private let longTask: (any LongTaskCoordinating)?
    /// Clipboard access for the Paste affordance (injected so tests can can content).
    private let pasteboard: any PasteboardReading
    /// Lock Screen presence of the running live session (Live Activity banner with pause/stop).
    /// Nil in tests/previews — then no banner, everything else unchanged.
    private let liveActivity: (any LiveSessionActivityPresenting)?
    /// Tokens for the Live-Activity button commands. Kept in a Sendable bag whose own deinit
    /// removes the observers — so this MainActor class needs no deinit that touches isolated state.
    private let commandObservers = NotificationObserverBag()

    private var captureTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?

    private let primingDefaultsKey = "didPrimeMic"        // shared with Out — one mic grant

    public init(
        understand: any UnderstandUseCase,
        explain: any ExplainExpressionUseCase,
        voiceCapture: any VoiceCaptureUseCase,
        liveTranslate: any LiveTranslateUseCase,
        pronounce: any PlayPronunciationUseCase,
        saveExpression: any SaveExpressionUseCase,
        studyList: any StudyListUseCase,
        isConfigured: Bool,
        isLiveConfigured: Bool = true,
        longTask: (any LongTaskCoordinating)? = nil,
        pasteboard: any PasteboardReading = SystemPasteboard(),
        liveActivity: (any LiveSessionActivityPresenting)? = nil
    ) {
        self.understand = understand
        self.explain = explain
        self.voiceCapture = voiceCapture
        self.liveTranslate = liveTranslate
        self.pronounce = pronounce
        self.saveExpression = saveExpression
        self.studyList = studyList
        self.isConfigured = isConfigured
        self.isLiveConfigured = isLiveConfigured
        self.longTask = longTask
        self.pasteboard = pasteboard
        self.liveActivity = liveActivity
        // The Live Activity's pause/stop buttons run their intents in the APP process and post
        // these commands. Observed by the view model (not the view): with the screen locked no
        // view is updating, but this object lives as long as the tab does. Main-queue delivery →
        // hop back into MainActor isolation.
        commandObservers.observers = [
            NotificationCenter.default.addObserver(
                forName: .liveTranslationPauseCommand, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.toggleLivePause() }
            },
            NotificationCenter.default.addObserver(
                forName: .liveTranslationStopCommand, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopLive() }   // guarded: no-op unless listening
            },
        ]
    }

    // MARK: Derived

    public var isListening: Bool { phase == .listening }
    public var canSubmit: Bool { !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var needsAPIKey: Bool { !isConfigured }
    /// Online mode needs the Soniox key (banner + disabled Listen button when missing).
    public var needsLiveAPIKey: Bool { !isLiveConfigured }

    // MARK: Paste affordance (the action button doubles as Paste while the field is empty)

    /// The action button renders (and acts) as PASTE: nothing to submit yet, but the clipboard has
    /// text one tap away. Pasting fills the field, which flips the button back to Translate/Explain.
    /// Suppressed while listening/processing — mid-dictation the (disabled) button keeps showing the
    /// MODE action instead of churning Paste→Translate as partial transcripts arrive.
    public var showsPasteAction: Bool {
        !canSubmit && clipboardHasText && phase != .listening && phase != .processing
    }

    /// The action button is tappable: either there's input to submit or a clipboard text to paste.
    /// (Empty field + empty clipboard = disabled Translate/Explain button.)
    public var hasActionAvailable: Bool { canSubmit || clipboardHasText }

    /// Re-read the clipboard's has-text METADATA (never triggers the iOS paste banner). Called on
    /// screen appear, on returning to the foreground (the clipboard changes while backgrounded),
    /// and when the field is cleared.
    public func refreshClipboardState() {
        let hasText = pasteboard.hasText
        if hasText != clipboardHasText { clipboardHasText = hasText }   // equal → no @Observable churn
    }

    /// Keep `clipboardHasText` honest for as long as the screen is visible. iOS posts
    /// `UIPasteboard.changedNotification` only for changes made by THIS app or when the app becomes
    /// active — a change made by another process while we are already in the foreground (Universal
    /// Clipboard from a Mac, a password manager's auto-clear, Shortcuts, a keyboard extension) is
    /// silent. Left unrefreshed, the slot either kept a Paste control the system had already greyed
    /// out (no Explain/Translate anywhere on the screen) or a disabled mode button with text one tap
    /// away. `hasText` is a metadata read and never triggers the paste banner; the interval is a
    /// parameter so tests can run the loop fast. Runs until cancelled — bind it to the screen with
    /// `.task`.
    public func monitorClipboard(every interval: Duration = .seconds(1)) async {
        while !Task.isCancelled {
            refreshClipboardState()
            try? await Task.sleep(for: interval)
        }
    }

    /// Fill the input with what the SYSTEM paste control delivered (its tap IS the pasteboard
    /// consent, so no "Allow Paste?" dialog is ever shown — the reason the read doesn't happen
    /// here). The field becoming non-empty flips the button to Translate/Explain; the user then
    /// submits DELIBERATELY — pasting never auto-runs the request.
    public func pasteIntoInput(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing USABLE (whitespace-only — where `hasText` would still say true). Mark the
            // clipboard unusable so the slot flips back to the mode action instead of staying a
            // do-nothing Paste.
            clipboardHasText = false
            return
        }
        source = text
    }

    /// The studied-language rendering — the card headline, the TTS source, and the study card's
    /// front. We study the language being LEARNED, never the user's own language.
    public var sourceText: String { studied ?? "" }

    public enum MicStatus { case idle, listening, processing }
    public var micStatus: MicStatus {
        switch phase {
        case .listening: .listening
        case .processing: .processing
        default: .idle
        }
    }

    // MARK: Mic / capture (English)

    /// PUSH-TO-TALK press (finger down on the mic): start capturing. If the mic is ALREADY on (the
    /// widget deep link auto-starts it), the press is a no-op — the matching release then stops and
    /// submits, so a tap still ends a routed capture. Unprimed mic shows the priming sheet instead
    /// (the sheet cancels the hold; capture starts on the next press).
    public func micPressBegan() {
        guard phase != .listening else { return }
        if Prefs.store.bool(forKey: primingDefaultsKey) {
            startListening()
        } else {
            showMicPriming = true
        }
    }

    /// PUSH-TO-TALK release (finger up): stop capturing and run Translate/Explain on what was heard
    /// (nothing heard → back to idle). No-op unless listening — a release after the priming sheet
    /// or a failed start has nothing to stop.
    public func micPressEnded() {
        guard phase == .listening else { return }
        stopListening()
    }

    /// The SYSTEM ended the hold (permission alert, incoming call, Control Center, scroll claimed
    /// the touch, backgrounding) — the user didn't lift the finger to ask for anything, so stop the
    /// mic WITHOUT submitting: a request must never fire off a half-finished utterance.
    public func micPressCancelled() {
        guard phase == .listening else { return }
        captureTask?.cancel()
        captureTask = nil
        phase = .idle
    }

    /// Start voice input WITHOUT a press being involved — used by the Lock Screen widget deep link
    /// so the mic comes on the moment the app opens. Idempotent (guards `.listening`) because
    /// iOS 26 can deliver the widget URL twice. Shows the priming sheet first if the mic hasn't
    /// been primed yet; confirming then STILL auto-starts (see `routedStartPending`).
    public func beginVoiceInput() {
        guard phase != .listening else { return }
        if Prefs.store.bool(forKey: primingDefaultsKey) {
            startListening()
        } else {
            routedStartPending = true
            showMicPriming = true
        }
    }

    /// True while the priming sheet on screen was opened by the ROUTED `beginVoiceInput` (widget) —
    /// that flow promised a hands-free live mic, so confirming resumes the auto-start. A capture
    /// running without a finger down is safe under push-to-talk: a press on it is a no-op and the
    /// release (or VoiceOver activate) stops-and-submits.
    private var routedStartPending = false

    public func confirmPriming() {
        Prefs.store.set(true, forKey: primingDefaultsKey)
        // Read BEFORE closing the sheet — showMicPriming's didSet consumes the flags on any close.
        let resumeRoutedStart = routedStartPending
        let resumeLiveStart = liveStartPending
        showMicPriming = false
        // Press-originated priming must NOT auto-start: the finger left the button when the sheet
        // appeared, so an auto-started capture would have no release to stop it — the user just
        // holds again. The routed (widget) flow has no finger at all; it keeps its auto-start.
        // The Online Listen button is a TOGGLE (tap already ended), so its confirm also resumes.
        // MUTUALLY EXCLUSIVE: both flags can theoretically be armed (a widget deep link landing
        // while the Online priming sheet is up) — never start two captures; the visible mode wins.
        if resumeLiveStart, mode == .online {
            startLive()
        } else if resumeRoutedStart, mode != .online {
            startListening()
        }
    }

    public func cancelPriming() { showMicPriming = false }

    private func startListening() {
        // A still-in-flight request would flip phase to .result/.failed MID-hold — hijacking the
        // live capture and swallowing the release (its `.listening` guard would fail, leaving the
        // mic hot). Starting a new capture supersedes the old request; cancel it.
        requestTask?.cancel()
        requestTask = nil
        errorMessage = nil
        isOffline = false
        needsSubscription = false
        studied = nil
        translations = []
        explanation = nil
        generatedSource = nil
        generatedMode = nil
        source = ""
        phase = .listening
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await transcript in self.voiceCapture() {
                    guard self.phase == .listening else { break }   // a late value mustn't overwrite after stop
                    self.source = transcript.text
                }
                self.captureEndedNaturally()
            } catch is CancellationError {
                // stopped by the user; handled in stopListening
            } catch {
                self.captureFailed(error)
            }
        }
    }

    private func stopListening() {
        captureTask?.cancel()
        captureTask = nil
        if canSubmit { submit() } else { phase = .idle }
    }

    private func captureEndedNaturally() {
        captureTask = nil
        guard phase == .listening else { return }
        if canSubmit { submit() } else { phase = .idle }
    }

    // MARK: Online (live translation)

    /// The Listen button opened the priming sheet — confirming should start the session (the tap
    /// already ended; unlike push-to-talk there is no held finger to conflict with).
    private var liveStartPending = false
    /// "New" was tapped while the old session drains — its tail text updates must not repopulate
    /// the freshly cleared screen (the session still SAVES in full; only the display is reset).
    private var liveClearPending = false

    /// The Listen button: one tap starts a session, the next tap gracefully ends it (the finished
    /// session is saved to History by the use case).
    public func toggleLive() {
        if isLiveListening {
            stopLive()
        } else if Prefs.store.bool(forKey: primingDefaultsKey) {
            startLive()
        } else {
            liveStartPending = true
            showMicPriming = true
        }
    }

    /// Start a live session WITHOUT a tap — the Lock Screen widget deep link, mirroring
    /// `beginVoiceInput`. IDEMPOTENT (never a toggle): iOS 26 can deliver the widget URL twice,
    /// and a second delivery must not stop the session the first one started. Unprimed mic shows
    /// the priming sheet; confirming resumes the start (`liveStartPending`). With no Soniox key
    /// this is a no-op — same as the disabled Listen button (the screen already shows the banner).
    public func beginLiveInput() {
        guard !isLiveListening, !isLiveStopping, !needsLiveAPIKey else { return }
        if Prefs.store.bool(forKey: primingDefaultsKey) {
            startLive()
        } else {
            liveStartPending = true
            showMicPriming = true
        }
    }

    private func startLive() {
        guard !isLiveListening, liveTask == nil else { return }
        liveErrorMessage = nil
        liveText = .empty
        liveLevel = 0
        isLiveListening = true
        isLiveStopping = false
        isLivePaused = false
        liveClearPending = false
        // The direction toggle decides which language is LISTENED TO and which is produced.
        let studiedCode = StudiedLanguage.current.languageCode
        let nativeCode = TargetLanguage.current.languageCode
        let from = isLiveReversed ? nativeCode : studiedCode
        let to = isLiveReversed ? studiedCode : nativeCode
        liveTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in self.liveTranslate.start(studiedLanguage: from,
                                                                nativeLanguage: to) {
                    switch event {
                    case .listening:
                        // Mic + socket are actually up → put the session on the Lock Screen.
                        self.liveActivity?.sessionStarted(direction: self.liveDirectionLabel)
                    case .level(let level):
                        // Small-delta gate: the level arrives ~20×/s; skipping sub-visible changes
                        // keeps @Observable from re-rendering the whole screen on noise.
                        if self.isLiveListening, !self.isLiveStopping,
                           abs(level - self.liveLevel) > 0.02 || (level == 0) != (self.liveLevel == 0) {
                            self.liveLevel = level
                        }
                    case .text(let text):
                        // After "New" the drain tail belongs to the SAVED session, not the screen.
                        if !self.liveClearPending { self.liveText = text }
                    case .finished:
                        break   // history is saved by the use case; UI keeps the transcript on screen
                    }
                }
            } catch {
                self.liveErrorMessage = Self.liveMessage(for: error)
            }
            self.isLiveListening = false
            self.isLiveStopping = false
            self.isLivePaused = false
            self.liveClearPending = false
            self.liveLevel = 0
            self.liveTask = nil
            self.liveActivity?.sessionEnded()   // stopped, failed, or auto-stopped — banner off
        }
    }

    /// "EN → RU"-style Live Activity label: the language LISTENED TO → the language produced.
    private var liveDirectionLabel: String {
        let studied = StudiedLanguage.current.abbreviation
        let native = TargetLanguage.current.abbreviation
        return isLiveReversed ? "\(native) → \(studied)" : "\(studied) → \(native)"
    }

    /// The Pause button: quickly mute the session (nothing recognized or recorded while paused;
    /// the connection stays warm) and just as quickly bring the translation back.
    public func toggleLivePause() {
        guard isLiveListening, !isLiveStopping else { return }
        isLivePaused.toggle()
        liveLevel = 0
        let paused = isLivePaused
        liveActivity?.sessionPaused(paused)
        Task { [weak self] in await self?.liveTranslate.setPaused(paused) }
    }

    /// The direction toggle: flip which language is recognized and which is produced. On a RUNNING
    /// session (listening, translating, or paused) the adapter finalizes the current tail, draws a
    /// divider line in both transcripts, and continues in the opposite direction — same session,
    /// same recording. With no session running it changes only the setting for the next start.
    public func toggleLiveDirection() {
        isLiveReversed.toggle()
        guard isLiveListening, !isLiveStopping else { return }
        liveActivity?.directionChanged(liveDirectionLabel)
        Task { [weak self] in await self?.liveTranslate.switchLanguages() }
    }

    /// The New button: the current session is SAVED as usual (graceful stop → History, recording
    /// included) and the screen clears for a fresh one. With nothing running it just clears.
    public func newLiveSession() {
        if isLiveListening {
            liveClearPending = true
            stopLive()
        }
        liveText = .empty
        liveErrorMessage = nil
        liveLevel = 0
    }

    /// Graceful stop: the session drains its final words, emits `.finished`, and the stream ends —
    /// the consuming task above then resets the flags. Idempotent.
    private func stopLive() {
        guard isLiveListening, !isLiveStopping else { return }
        isLiveStopping = true
        liveLevel = 0
        Task { [weak self] in await self?.liveTranslate.stop() }
    }

    private static func liveMessage(for error: Error) -> String {
        guard let live = error as? LiveTranslationError else {
            return Loc.t("Что-то пошло не так. Попробуйте ещё раз.", "Something went wrong. Try again.")
        }
        switch live {
        case .permissionDenied:
            return Loc.t("Нет доступа к микрофону. Включите его в Настройках.",
                         "No microphone access. Enable it in Settings.")
        case .notConfigured:
            return Loc.t("Нет ключа Soniox API — онлайн-перевод не работает. Добавьте ключ в Secrets.xcconfig.",
                         "No Soniox API key — online translation won't work. Add a key in Secrets.xcconfig.")
        case .unauthorized:
            return Loc.t("Сервис распознавания не принял ключ API.",
                         "The speech service rejected the API key.")
        case .balanceExhausted:
            return Loc.t("Закончился баланс Soniox — пополните счёт в console.soniox.com.",
                         "The Soniox balance is exhausted — add funds at console.soniox.com.")
        case .offline:
            return Loc.t("Нет соединения. Проверьте интернет и попробуйте снова.",
                         "No connection. Check the internet and try again.")
        case .serviceUnavailable:
            return Loc.t("Сервис распознавания недоступен. Попробуйте позже.",
                         "The speech service is unavailable. Try later.")
        case .subscriptionRequired:
            return Loc.t("Онлайн-перевод доступен по подписке.", "Online translation is part of the subscription.")
        case .underlying(let detail):
            return Loc.t("Ошибка онлайн-перевода: \(detail)", "Online translation error: \(detail)",
                         "Erreur de traduction en direct : \(detail)", "Error de traducción en vivo: \(detail)",
                         "Live-Übersetzungsfehler: \(detail)", "Errore di traduzione dal vivo: \(detail)")
        }
    }

    private func captureFailed(_ error: Error) {
        captureTask = nil
        phase = .failed
        switch error {
        case SpeechRecognitionError.permissionDenied:
            errorMessage = Loc.t(
                "Нет доступа к микрофону или распознаванию речи. Включите в Настройках, либо введите текст вручную.",
                "No access to the microphone or speech recognition. Enable it in Settings, or type the text instead.")
        case SpeechRecognitionError.unavailable:
            errorMessage = Loc.t("Распознавание речи недоступно. Введите текст вручную.",
                                 "Speech recognition is unavailable. Type the text instead.")
        case SpeechRecognitionError.noSpeechDetected:
            errorMessage = Loc.t("Не расслышал. Попробуйте ещё раз.", "Didn't catch that. Try again.")
        case SpeechRecognitionError.underlying(let detail):
            errorMessage = Loc.t("Не удалось распознать речь: \(detail). Можно ввести текст вручную.",
                                 "Couldn't recognize speech: \(detail). You can type the text instead.",
                                 "Impossible de reconnaître la parole : \(detail). Vous pouvez saisir le texte à la place.",
                                 "No se pudo reconocer el habla: \(detail). Puedes escribir el texto.",
                                 "Sprache konnte nicht erkannt werden: \(detail). Du kannst den Text eingeben.",
                                 "Impossibile riconoscere il parlato: \(detail). Puoi digitare il testo.")
        default:
            errorMessage = Loc.t("Не удалось распознать речь. Введите текст вручную.",
                                 "Couldn't recognize speech. Type the text instead.")
        }
    }

    // MARK: Translate / Explain

    /// Auto-retry after the network returns (RootView calls this on reconnect): replay the last
    /// request, but ONLY when we're showing an offline failure — re-running any other error would just
    /// fail the same way. The source/mode are still set, so `submit()` faithfully replays it.
    public func retryOnReconnect() {
        guard phase == .failed, isOffline, canSubmit else { return }
        submit()
    }

    /// One button: act on fresh input, or re-run when a result is already shown. The current `mode`
    /// decides whether the LLM TRANSLATES the input into the native language or EXPLAINS its nuance.
    public func submit() {
        guard mode != .online else { return }   // Online has no submit — the Listen toggle drives it
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let studiedLang = StudiedLanguage.current.promptName
        let nativeLang = TargetLanguage.current.promptName
        let mode = self.mode
        // Use the routed sibling-variant context only while the input still matches what it was
        // captured for (a user edit of `source` invalidates it).
        let explainAlts = (mode == .explain && explainAlternativesText == text) ? explainAlternatives : []
        requestTask?.cancel()
        phase = .processing
        errorMessage = nil
        isOffline = false
        needsSubscription = false
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch mode {
                case .translate:
                    let result = try await withBackgroundCompletion(self.longTask, .translation) {
                        try await self.understand(text, studiedLanguage: studiedLang, nativeLanguage: nativeLang)
                    }
                    // A push-to-talk press may have superseded this request while its result was
                    // already enqueued — applying it would flip the phase mid-hold and swallow the
                    // release. Cancellation wins over an already-computed result.
                    guard !Task.isCancelled else { return }
                    self.studied = result.studied         // headline + TTS
                    self.translations = result.variants   // 1–5 translations (+ context per variant)
                    self.explanation = nil
                case .explain:
                    let result = try await withBackgroundCompletion(self.longTask, .explanation) {
                        try await self.explain(text, studiedLanguage: studiedLang, nativeLanguage: nativeLang, image: nil, alternatives: explainAlts)
                    }
                    guard !Task.isCancelled else { return }   // see .translate above
                    self.studied = result.studied
                    self.explanation = result
                    self.translations = []
                case .online:
                    return   // unreachable — submit() guards mode != .online
                }
                self.generatedSource = text
                self.generatedMode = mode
                self.isSaved = false
                self.savedExpressionID = nil
                self.resultsGeneration += 1
                self.phase = .result
            } catch is CancellationError {
                // superseded
            } catch LLMError.cancelled {
                // Superseded by a newer request — e.g. toggling Translate/Explain mid-generation cancels
                // this one. The adapter maps the in-flight URLSession cancel to LLMError.cancelled, so it
                // arrives HERE (not as CancellationError). Swallow it: never surface a self-inflicted
                // cancel as a failure (that left the screen stuck in `.failed`).
            } catch {
                self.handleRequestError(error)
            }
        }
    }

    /// Open this screen in Explain mode for an externally-supplied phrase (routed from See it / History
    /// / Say it) and run it immediately. The phrase is explained on its own — no source-photo context;
    /// `alternatives` (sibling Say-it phrasings) is the only extra context, used to contrast registers.
    public func startExplain(text: String, alternatives: [String] = []) {
        if mode == .online { stopLive() }   // routed Explain takes over the screen — end the session
        mode = .explain
        source = text
        explainAlternatives = alternatives
        explainAlternativesText = alternatives.isEmpty ? nil : text
        submit()
    }

    /// Switch the Translate/Explain mode from the ON-SCREEN selector — remembered across launches.
    public func selectMode(_ newMode: Mode) { applyMode(newMode, persist: true) }

    /// Programmatic mode change (widget deep link, shared-in text). Same behavior, but SESSION-ONLY:
    /// a routed action must never overwrite the mode the user explicitly chose on the selector.
    public func routeMode(_ newMode: Mode) { applyMode(newMode, persist: false) }

    /// With a result already shown (or in flight), re-run the same input in the new mode so you see
    /// it both ways; otherwise just remember the choice.
    private func applyMode(_ newMode: Mode, persist: Bool) {
        guard newMode != mode else { return }
        let oldMode = mode
        stashCurrentResult()   // keep the finished answer of the mode we're leaving
        mode = newMode
        if persist { Prefs.store.set(newMode.rawValue, forKey: Mode.storageKey) }
        // Leaving Online mid-session: end it GRACEFULLY (it saves to History) — never keep a hot
        // mic under a screen that no longer shows it.
        if oldMode == .online { stopLive() }
        // Entering Online: park the text-mode machinery untouched (it resumes when they switch
        // back); nothing to re-run — the live screen starts idle.
        if newMode == .online {
            requestTask?.cancel()
            requestTask = nil
            if phase == .listening {
                captureTask?.cancel()
                captureTask = nil
                phase = .idle
            }
            if phase == .processing { phase = .idle }
            stopPlayback()
            return
        }
        // Re-run the input the result was GENERATED from, not an edited-but-unsubmitted draft —
        // running new text happens only via the button. (A deliberately CLEARED field falls through
        // to the reset branch instead of resurrecting deleted text.)
        if phase == .result, canSubmit, let generatedSource { source = generatedSource }
        // The on-screen result already belongs to the target mode (round trip through Online):
        // it is still valid — re-firing would waste a request and reset the bookmark state.
        if phase == .result, newMode == generatedMode { return }
        // This mode already answered THIS input: show the kept answer — a model call happens only
        // on an explicit user action, never because the user navigated between modes.
        let input = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.isEmpty, let cached = modeResults[newMode], cached.generatedSource == input {
            restoreResult(cached, for: newMode)
            return
        }
        // No kept answer for this mode+input: run it — including after a FAILURE (e.g. the model
        // was unavailable in the previous mode), so switching mode retries instead of staying stuck.
        if canSubmit, phase == .result || phase == .processing || phase == .failed {
            submit()
        } else {
            requestTask?.cancel()   // an in-flight old-mode result must not land under the new mode
            studied = nil
            translations = []
            explanation = nil
            generatedSource = nil
            generatedMode = nil
            // Nothing to re-run (no input): drop any stale result/in-flight/error back to idle.
            if phase == .result || phase == .processing || phase == .failed {
                phase = .idle
                errorMessage = nil
                isOffline = false
                needsSubscription = false
            }
        }
    }

    /// Snapshot the visible finished result under the mode that produced it (no-op otherwise).
    private func stashCurrentResult() {
        guard phase == .result, let generatedMode, let generatedSource else { return }
        modeResults[generatedMode] = CachedModeResult(
            studied: studied, translations: translations, explanation: explanation,
            generatedSource: generatedSource, isSaved: isSaved, savedExpressionID: savedExpressionID
        )
    }

    /// Put a kept answer back on screen — the exact state the mode was left in, bookmark included.
    private func restoreResult(_ cached: CachedModeResult, for newMode: Mode) {
        requestTask?.cancel()   // an in-flight other-mode request must not land over the restored view
        requestTask = nil
        studied = cached.studied
        translations = cached.translations
        explanation = cached.explanation
        generatedSource = cached.generatedSource
        generatedMode = newMode
        source = cached.generatedSource
        isSaved = cached.isSaved
        savedExpressionID = cached.savedExpressionID
        resultsGeneration += 1   // an in-flight save from the previous mode must not attach here
        errorMessage = nil
        isOffline = false
        needsSubscription = false
        phase = .result
    }

    /// The screen is leaving (tab switch / navigation away). Stops anything that must not keep
    /// running from a hidden tab, then drops an edit the user typed but never submitted, so on
    /// return the input still matches the result on screen — the only way to run the new text is to
    /// actually press the button.
    public func screenDisappeared() {
        // The push-to-talk mic must never keep recording from a hidden tab — and unlike
        // stopListening(), leaving must NOT auto-submit: no LLM request may fire from a screen the
        // user isn't on. A LIVE session is the opposite by design: the user asked for
        // keep-listening-in-background, so a tab switch (like backgrounding) leaves it running.
        if phase == .listening {
            captureTask?.cancel()
            captureTask = nil
            phase = .idle
        }
        stopPlayback()
        // Trimmed comparison: `generatedSource` stores the trimmed submit text, so a whitespace-only
        // difference (e.g. dictation's trailing space) must not count as an edit.
        guard phase == .result, let generatedSource,
              source.trimmingCharacters(in: .whitespacesAndNewlines) != generatedSource else { return }
        source = generatedSource
    }

    private func handleRequestError(_ error: Error) {
        phase = .failed
        guard let llm = error as? LLMError else {
            errorMessage = Loc.t("Что-то пошло не так. Попробуйте ещё раз.", "Something went wrong. Try again.")
            return
        }
        switch llm {
        case .notConfigured:
            isOffline = true
            errorMessage = Loc.t("Нет ключа Claude API. Добавьте его, чтобы переводить.",
                                 "No Claude API key. Add one to translate.")
        case .overloaded:
            errorMessage = Loc.t("Сервис перегружен, попробуйте позже.", "Service is overloaded — try later.")
        case .offline:
            isOffline = true
            errorMessage = Loc.t("Нет соединения. Проверьте интернет и попробуйте снова.",
                                 "No connection. Check the internet and try again.")
        case .timedOut:
            errorMessage = Loc.t("Сервис не ответил вовремя. Попробуйте ещё раз.",
                                 "The service didn't respond in time. Try again.")
        case .responseTooLong:
            errorMessage = Loc.t("Слишком много текста для одного запроса. Попробуйте часть поменьше.",
                                 "Too much text to handle at once. Try a smaller part.")
        case .invalidOutput:
            errorMessage = Loc.t("Не удалось разобрать ответ. Попробуйте ещё раз.",
                                 "Couldn't parse the response. Try again.")
        case .cancelled:
            errorMessage = Loc.t("Запрос отменён.", "Request cancelled.")
        case .subscriptionRequired(let retryAfter):
            needsSubscription = true
            errorMessage = subscriptionLimitMessage(retryAfter: retryAfter)
        case .requestFailed:
            errorMessage = Loc.t("Сервис недоступен. Попробуйте позже.", "Service unavailable. Try later.")
        }
    }

    // MARK: Play (the English side)

    public func play() {
        if isPlaying { stopPlayback(); return }   // tap again while speaking = stop
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        playTask?.cancel()
        isPlaying = true
        playTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await state in self.pronounce(text) where state == .finished { break }
            } catch {
                // playback failure is non-fatal
            }
            if !Task.isCancelled { self.isPlaying = false }
        }
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }

    // MARK: Save / unsave (enrich-then-store)

    public func toggleSave() {
        guard let studied, !studied.isEmpty else { return }
        if isSaved {
            isSaved = false                                  // instant UI
            let storedID = savedExpressionID
            savedExpressionID = nil
            if let storedID {
                Task { [weak self] in try? await self?.studyList.delete(id: storedID) }
            }
        } else {
            isSaved = true                                   // instant UI; enrich+store in background
            // We study the STUDIED-language rendering (the headline), with the native translation as
            // its gloss. In Explain mode there's no direct gloss, so enrich derives it.
            let en = studied
            let knownRU = translations.first?.text
            let generation = resultsGeneration
            Task { [weak self] in
                guard let self else { return }
                do {
                    let stored = try await self.saveExpression(en: en, knownRU: knownRU, context: "")
                    if self.resultsGeneration != generation {
                        // Regenerated while saving — keep it persisted; drop the optimistic mapping only.
                    } else if self.isSaved {
                        self.savedExpressionID = stored.id
                    } else {
                        try? await self.studyList.delete(id: stored.id)   // user un-saved while saving
                    }
                } catch {
                    self.isSaved = false                     // revert on failure
                    self.saveError = Loc.t("Не удалось сохранить в изучаемое.",
                                           "Couldn't save to your study list.")
                }
            }
        }
    }

    public func clearSaveError() { saveError = nil }

    public func reset() {
        captureTask?.cancel(); requestTask?.cancel(); playTask?.cancel()
        phase = .idle
        studied = nil
        translations = []
        explanation = nil
        generatedSource = nil
        generatedMode = nil
        source = ""
        errorMessage = nil
        isPlaying = false
        isSaved = false
        savedExpressionID = nil
        explainAlternatives = []
        explainAlternativesText = nil
    }
}

/// Owns NotificationCenter observer tokens and removes them when deallocated. `@unchecked Sendable`:
/// `observers` is written once (from the owner's init) and read only in `deinit` (exclusive access).
private final class NotificationObserverBag: @unchecked Sendable {
    var observers: [NSObjectProtocol] = []
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
