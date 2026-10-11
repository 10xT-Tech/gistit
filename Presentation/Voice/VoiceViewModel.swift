//
//  VoiceViewModel.swift
//  EnglishHelper — Presentation
//
//  "Как сказать" (RU→EN). Drives: idle / listening / processing / results / failed, plus offline
//  and mic permission priming. Consumes USE CASES only (no Speech/AVFoundation here).
//

import Foundation
import Domain

@MainActor
@Observable
public final class VoiceViewModel {
    public enum Phase: Equatable { case idle, listening, processing, results, failed }

    /// What the screen generates: phrasings of ONE thought ("how to say"), or the useful phrases for
    /// a described SITUATION ("what to say"). Both produce phrase cards in the chosen tone.
    public enum Mode: String, CaseIterable, Sendable {
        case howToSay, whatToSay
        public var title: String {
            switch self {
            case .howToSay: Loc.t("Как сказать", "How to say", "Comment dire", "Cómo decir", "Wie sagt man", "Come si dice")
            case .whatToSay: Loc.t("Что сказать", "What to say", "Quoi dire", "Qué decir", "Was sagen", "Cosa dire")
            }
        }
        /// Last-used mode, persisted so the screen comes back the way the user left it (like tone).
        static let storageKey = "sayItMode"
        static var current: Mode {
            Mode(rawValue: Prefs.store.string(forKey: storageKey) ?? "") ?? .howToSay
        }
    }

    // UI state
    public private(set) var phase: Phase = .idle
    /// Mutated only via selectMode/routeMode (preserving the re-run logic). Persisted ONLY by
    /// `selectMode` (an explicit tap on the on-screen selector) — a routed change (widget deep link)
    /// is session-only, so it can never silently overwrite the user's saved preference.
    public private(set) var mode: Mode = Mode.current
    public var intent: String = "" {                     // editable transcript / typed input
        // Clearing the field (the ✕ button or deleting everything) re-arms the Paste affordance —
        // re-check the clipboard so the action button can flip to Paste (or disable) immediately.
        didSet { if intent.isEmpty && !oldValue.isEmpty { refreshClipboardState() } }
    }
    /// Last observed "clipboard holds text" state (refreshed on appear / foreground / field clear).
    /// Drives the action button's Paste mode; the metadata check never triggers the iOS paste banner.
    public private(set) var clipboardHasText = false
    /// Tone/register for the generated phrases — chosen on-screen, persisted (shared with the
    /// "Понять" compose path via `ToneOfVoice.current`).
    public var tone: ToneOfVoice = ToneOfVoice.current {
        didSet { Prefs.store.set(tone.rawValue, forKey: ToneOfVoice.storageKey) }
    }
    public private(set) var variants: [PhraseVariant] = []
    public private(set) var errorMessage: String?
    /// A SAVE failure shown independently of `phase` (the results stay on screen); the request-level
    /// `errorMessage` only renders in `.failed`, so a background save error needs its own channel.
    public private(set) var saveError: String?
    public private(set) var isOffline = false
    /// The free plan's limit stopped the request — the screen offers the subscription instead of Retry.
    public private(set) var needsSubscription = false
    public private(set) var playingVariantID: UUID?
    public var showMicPriming = false {
        // The sheet can close WITHOUT confirm/cancelPriming (interactive swipe-down just flips the
        // binding) — any close must consume a pending routed auto-start, or a LATER press-originated
        // confirm would wrongly start a hands-free capture. confirmPriming reads the flag first.
        didSet { if !showMicPriming { routedStartPending = false } }
    }

    private var savedVariantIDs: Set<UUID> = []           // optimistic "saved" flag (instant UI)
    private var savedExpressionIDs: [UUID: UUID] = [:]    // variant.id → stored Expression.id
    /// The input the on-screen variants were generated from — restored on leaving the screen so an
    /// edit the user never submitted can't sit above results it doesn't match.
    private var generatedIntent: String?
    /// Bumped on every new result set; lets an in-flight save tell "user un-saved" from "results
    /// were regenerated" so a regenerate can't silently delete a phrase the user just bookmarked.
    private var resultsGeneration = 0

    // Dependencies (use cases)
    private let howToSay: any HowToSayUseCase
    private let regenerateHowToSay: any RegenerateHowToSayUseCase
    private let whatToSay: any WhatToSayUseCase
    private let voiceCapture: any VoiceCaptureUseCase
    private let pronounce: any PlayPronunciationUseCase
    private let saveExpression: any SaveExpressionUseCase
    private let studyList: any StudyListUseCase
    private let isConfigured: Bool
    /// Clipboard access for the Paste affordance (injected so tests can can content).
    private let pasteboard: any PasteboardReading

    private var captureTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?

    private let primingDefaultsKey = "didPrimeMic"

    public init(
        howToSay: any HowToSayUseCase,
        regenerateHowToSay: any RegenerateHowToSayUseCase,
        whatToSay: any WhatToSayUseCase,
        voiceCapture: any VoiceCaptureUseCase,
        pronounce: any PlayPronunciationUseCase,
        saveExpression: any SaveExpressionUseCase,
        studyList: any StudyListUseCase,
        isConfigured: Bool,
        pasteboard: any PasteboardReading = SystemPasteboard()
    ) {
        self.howToSay = howToSay
        self.regenerateHowToSay = regenerateHowToSay
        self.whatToSay = whatToSay
        self.voiceCapture = voiceCapture
        self.pronounce = pronounce
        self.saveExpression = saveExpression
        self.studyList = studyList
        self.isConfigured = isConfigured
        self.pasteboard = pasteboard
    }

    // MARK: Derived

    public var isListening: Bool { phase == .listening }
    public var canSubmit: Bool { !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var needsAPIKey: Bool { !isConfigured }

    // MARK: Paste affordance (the action button doubles as Paste while the field is empty)

    /// The action button renders (and acts) as PASTE: nothing to submit yet, but the clipboard has
    /// text one tap away. Pasting fills the field, which flips the button back to the mode action.
    /// Suppressed while listening/processing — mid-dictation the (disabled) button keeps showing the
    /// MODE action instead of churning Paste→action as partial transcripts arrive. Same contract as
    /// the Get-it screen.
    public var showsPasteAction: Bool {
        !canSubmit && clipboardHasText && phase != .listening && phase != .processing
    }

    /// The action button is tappable: either there's input to submit or a clipboard text to paste.
    public var hasActionAvailable: Bool { canSubmit || clipboardHasText }

    /// Re-read the clipboard's has-text METADATA (never triggers the iOS paste banner). Called on
    /// screen appear, on returning to the foreground, and when the field is cleared.
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
    /// here). The field becoming non-empty flips the button back to the mode action; the user then
    /// submits DELIBERATELY — pasting never auto-runs the request.
    public func pasteIntoInput(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing USABLE (whitespace-only — where `hasText` would still say true). Mark the
            // clipboard unusable so the slot flips back to the mode action instead of staying a
            // do-nothing Paste.
            clipboardHasText = false
            return
        }
        intent = text
    }
    public func isSaved(_ variant: PhraseVariant) -> Bool { savedVariantIDs.contains(variant.id) }
    public func isPlaying(_ variant: PhraseVariant) -> Bool { playingVariantID == variant.id }

    public var micStatus: MicStatus {
        switch phase {
        case .listening: .listening
        case .processing: .processing
        default: .idle
        }
    }
    public enum MicStatus { case idle, listening, processing }

    // MARK: Mic / capture

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

    /// PUSH-TO-TALK release (finger up): stop capturing and submit what was heard (nothing heard →
    /// back to idle). No-op unless listening — a release after the priming sheet or a failed start
    /// has nothing to stop.
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
        // Read BEFORE closing the sheet — showMicPriming's didSet consumes the flag on any close.
        let resumeRoutedStart = routedStartPending
        showMicPriming = false
        // Press-originated priming must NOT auto-start: the finger left the button when the sheet
        // appeared, so an auto-started capture would have no release to stop it — the user just
        // holds again. The routed (widget) flow has no finger at all; it keeps its auto-start.
        if resumeRoutedStart { startListening() }
    }

    public func cancelPriming() { showMicPriming = false }

    private func startListening() {
        // A still-in-flight request would flip phase to .results/.failed MID-hold — hijacking the
        // live capture and swallowing the release (its `.listening` guard would fail, leaving the
        // mic hot). Starting a new capture supersedes the old request; cancel it.
        requestTask?.cancel()
        requestTask = nil
        errorMessage = nil
        isOffline = false
        needsSubscription = false
        variants = []
        generatedIntent = nil
        intent = ""
        phase = .listening
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await transcript in self.voiceCapture() {
                    guard self.phase == .listening else { break }   // a late value mustn't overwrite after stop
                    self.intent = transcript.text
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

    // MARK: Generate

    /// Auto-retry after the network returns (RootView calls this on reconnect): replay the last
    /// request, but ONLY when we're showing an offline failure — re-running any other error would just
    /// fail the same way. The intent/mode/tone are still set, so `submit()` faithfully replays it.
    public func retryOnReconnect() {
        guard phase == .failed, isOffline, canSubmit else { return }
        submit()
    }

    public func submit() {
        let text = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let studied = StudiedLanguage.current.promptName   // phrases are produced in the studied language
        let native = TargetLanguage.current.promptName     // notes + input normalization in native
        let tone = self.tone.register
        switch mode {
        case .howToSay:
            run(input: text) { try await self.howToSay(text, tone: tone, studiedLanguage: studied, nativeLanguage: native) }
        case .whatToSay:
            run(input: text) { try await self.whatToSay(text, tone: tone, studiedLanguage: studied, nativeLanguage: native) }
        }
    }

    public func regenerate() {
        let text = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let studied = StudiedLanguage.current.promptName
        let native = TargetLanguage.current.promptName
        let tone = self.tone.register
        switch mode {
        case .howToSay:
            run(input: text) { try await self.regenerateHowToSay(text, tone: tone, studiedLanguage: studied, nativeLanguage: native) }
        case .whatToSay:
            run(input: text) { try await self.whatToSay(text, tone: tone, studiedLanguage: studied, nativeLanguage: native, regenerate: true) }
        }
    }

    /// One button drives both: regenerate when results are shown, otherwise generate a fresh set.
    public func pick() {
        if phase == .results { regenerate() } else { submit() }
    }

    /// Switch between "how to say" (phrasings of one thought) and "what to say" (phrases for a
    /// situation) from the ON-SCREEN selector — remembered across launches.
    public func selectMode(_ newMode: Mode) { applyMode(newMode, persist: true) }

    /// Programmatic mode change (widget deep link). Same behavior, but SESSION-ONLY: a routed
    /// action must never overwrite the mode the user explicitly chose on the selector.
    public func routeMode(_ newMode: Mode) { applyMode(newMode, persist: false) }

    /// With results already shown (or in flight) and non-empty input, re-run in the new mode;
    /// otherwise just remember the choice (the prior results would be stale for the new mode).
    private func applyMode(_ newMode: Mode, persist: Bool) {
        guard newMode != mode else { return }
        mode = newMode
        if persist { Prefs.store.set(newMode.rawValue, forKey: Mode.storageKey) }
        // Re-run the input the results were GENERATED from, not an edited-but-unsubmitted draft —
        // generation for new text happens only via the button. (A deliberately CLEARED field falls
        // through to the reset branch instead of resurrecting deleted text.)
        if phase == .results, canSubmit, let generatedIntent { intent = generatedIntent }
        if canSubmit, phase == .results || phase == .processing {
            submit()                          // re-run the same input in the new mode
        } else if phase == .results || phase == .processing || phase == .failed {
            requestTask?.cancel()             // no input to re-run with → drop stale/in-flight/errored results
            variants = []
            generatedIntent = nil
            errorMessage = nil                // a stale error's Retry would otherwise re-run the NEW mode
            isOffline = false
            needsSubscription = false
            phase = .idle
        }
    }

    /// The screen is leaving (tab switch / navigation away). Stops anything that must not keep
    /// running from a hidden tab, then drops an edit the user typed but never submitted, so on
    /// return the input still matches the results on screen — the only way to generate for the new
    /// text is to actually press the button.
    public func screenDisappeared() {
        // The mic must never keep recording from a hidden tab — and unlike stopListening(), leaving
        // must NOT auto-submit: no LLM request may fire from a screen the user isn't on.
        if phase == .listening {
            captureTask?.cancel()
            captureTask = nil
            phase = .idle
        }
        stopPlayback()
        // Trimmed comparison: `generatedIntent` stores the trimmed submit text, so a whitespace-only
        // difference (e.g. dictation's trailing space) must not count as an edit.
        guard phase == .results, let generatedIntent,
              intent.trimmingCharacters(in: .whitespacesAndNewlines) != generatedIntent else { return }
        intent = generatedIntent
    }

    /// Pick a tone from the on-screen selector. With variants already shown (or in flight),
    /// immediately produce a fresh set in the new tone — "change the tone → get new variants".
    /// Otherwise just remember it for the next generation.
    public func selectTone(_ newTone: ToneOfVoice) {
        guard newTone != tone else { return }
        tone = newTone
        // Same rule as applyMode: re-run the GENERATED input, never an unsubmitted draft.
        if phase == .results, canSubmit, let generatedIntent { intent = generatedIntent }
        if canSubmit, phase == .results || phase == .processing { submit() }
    }

    private func run(input: String, _ operation: @escaping () async throws -> [PhraseVariant]) {
        requestTask?.cancel()
        phase = .processing
        errorMessage = nil
        isOffline = false
        needsSubscription = false
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await operation()
                // A push-to-talk press may have superseded this request while its result was
                // already enqueued — applying it would flip the phase mid-hold and swallow the
                // release. Cancellation wins over an already-computed result.
                guard !Task.isCancelled else { return }
                self.variants = result
                self.generatedIntent = input
                self.savedVariantIDs = []
                self.savedExpressionIDs = [:]
                self.resultsGeneration += 1
                self.phase = .results
            } catch is CancellationError {
                // superseded
            } catch LLMError.cancelled {
                // superseded by a newer request, or dropped on a mode switch — adapters map task
                // cancellation to LLMError.cancelled, so this (not CancellationError) is what we get.
                // Cancellation is always self-inflicted; never surface it as a failure.
            } catch {
                self.handleRequestError(error)
            }
        }
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
            errorMessage = Loc.t("Нет ключа Claude API. Добавьте его, чтобы получать варианты.",
                                 "No Claude API key. Add one to get options.")
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

    // MARK: Play

    public func play(_ variant: PhraseVariant) {
        if playingVariantID == variant.id { stopPlayback(); return }   // tap again = stop
        playTask?.cancel()
        playingVariantID = variant.id
        playTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await state in self.pronounce(variant.en) where state == .finished {
                    break
                }
            } catch {
                // playback failure is non-fatal
            }
            if !Task.isCancelled, self.playingVariantID == variant.id { self.playingVariantID = nil }
        }
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
        playingVariantID = nil
    }

    // MARK: Save / unsave (enrich-then-store)

    public func toggleSave(_ variant: PhraseVariant) {
        let id = variant.id
        if savedVariantIDs.contains(id) {
            savedVariantIDs.remove(id)                          // instant UI
            let storedID = savedExpressionIDs[id]
            savedExpressionIDs[id] = nil
            if let storedID {
                Task { [weak self] in try? await self?.studyList.delete(id: storedID) }
            }
        } else {
            savedVariantIDs.insert(id)                          // instant UI; enrich+store in background
            let generation = resultsGeneration
            Task { [weak self] in
                guard let self else { return }
                do {
                    let stored = try await self.saveExpression(
                        en: variant.en, knownRU: nil, context: variant.contextRU
                    )
                    if self.resultsGeneration != generation {
                        // Results were regenerated while saving — keep the expression persisted (the
                        // user DID bookmark it); just drop the now-defunct optimistic mapping.
                    } else if self.savedVariantIDs.contains(id) {
                        self.savedExpressionIDs[id] = stored.id
                    } else {
                        try? await self.studyList.delete(id: stored.id)   // user un-saved while saving
                    }
                } catch {
                    self.savedVariantIDs.remove(id)             // revert on failure
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
        variants = []
        generatedIntent = nil
        intent = ""
        errorMessage = nil
        playingVariantID = nil
    }
}
