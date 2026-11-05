//
//  VoiceViewModelTests.swift
//  EnglishHelperTests
//
//  "Как сказать" view-model behavior: happy path, error→offline mapping, save marking.
//

import Testing
import Foundation
import Domain
import Adapters
import Presentation

@Suite(.serialized) @MainActor struct VoiceViewModelTests {

    /// The mode/tone are persisted so the screen reopens as last used; each test starts from the
    /// defaults, not whatever a previous test (or app run on this simulator) left behind.
    init() {
        UserDefaults.standard.removeObject(forKey: "sayItMode")
        UserDefaults.standard.removeObject(forKey: "toneOfVoice")
    }

    private func makeVM(llm: any LLMClient = MockLLMClient(), isConfigured: Bool = true,
                        recognizer: any SpeechRecognizing = MockSpeechRecognizing(),
                        pasteboard: any PasteboardReading = VoiceMockPasteboard(text: nil)) -> VoiceViewModel {
        let history = MockHistoryRepository()
        let repo = MockExpressionRepository(seed: [])
        return VoiceViewModel(
            howToSay: HowToSayInteractor(llm: llm, history: history),
            regenerateHowToSay: RegenerateHowToSayInteractor(llm: llm, history: history),
            whatToSay: WhatToSayInteractor(llm: llm, history: history),
            voiceCapture: VoiceCaptureInteractor(recognizer: recognizer),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            saveExpression: SaveExpressionInteractor(
                enrich: EnrichExpressionInteractor(llm: llm), repository: repo
            ),
            studyList: StudyListInteractor(repository: repo),
            isConfigured: isConfigured,
            pasteboard: pasteboard
        )
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while !condition() {
            if clock.now - start > timeout { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func submitProducesThreeVariants() async throws {
        let vm = makeVM()
        vm.intent = "как сказать спасибо"
        vm.submit()
        try await waitUntil { vm.phase == .results }
        #expect(vm.phase == .results)
        #expect(vm.variants.count == 3)
    }

    @Test func whatToSayModeProducesSituationPhrases() async throws {
        let vm = makeVM()
        vm.selectMode(.whatToSay)
        #expect(vm.mode == .whatToSay)
        vm.intent = "приём у врача"
        vm.submit()
        try await waitUntil { vm.phase == .results }
        #expect(vm.phase == .results)
        // "What to say" returns a relevance-driven set (3–10), not a fixed three.
        #expect(vm.variants.count >= 3)
        #expect(vm.variants.count <= 10)
    }

    @Test func failureMapsToOfflineWhenNotConfigured() async throws {
        let vm = makeVM(llm: StubLLMClient(behavior: .failure(.notConfigured), latency: .milliseconds(1)))
        vm.intent = "привет"
        vm.submit()
        try await waitUntil { vm.phase == .failed }
        #expect(vm.phase == .failed)
        #expect(vm.isOffline)
    }

    @Test func switchingModeMidFlightWithoutInputDropsRequest() async throws {
        // A slow request keeps us in `.processing` so we can switch modes mid-flight.
        let vm = makeVM(llm: StubLLMClient(behavior: .success, latency: .milliseconds(200)))
        vm.intent = "как сказать спасибо"
        vm.submit()
        #expect(vm.phase == .processing)

        // Clear the input, then switch mode: nothing to re-run with → the in-flight request is
        // dropped and the screen returns to idle WITHOUT surfacing a cancellation error.
        vm.intent = ""
        vm.selectMode(.whatToSay)
        #expect(vm.phase == .idle)
        #expect(vm.variants.isEmpty)

        // The superseded request must not resurface results or an error after it unwinds.
        try await Task.sleep(for: .milliseconds(300))
        #expect(vm.phase == .idle)
        #expect(vm.variants.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    @Test func toggleSaveMarksVariantSaved() async throws {
        let vm = makeVM()
        vm.intent = "как сказать спасибо"
        vm.submit()
        try await waitUntil { vm.phase == .results }
        let variant = try #require(vm.variants.first)

        vm.toggleSave(variant)
        try await waitUntil { vm.isSaved(variant) }
        #expect(vm.isSaved(variant))
    }

    // MARK: State preservation (leave / return)

    /// Leaving the screen with results on screen drops an edit the user never submitted, so on
    /// return the input matches the visible variants. The results themselves are untouched — the
    /// only way to generate for the new text is to actually press the button.
    @Test func leavingScreenRevertsUnsubmittedEdit() async throws {
        let vm = makeVM()
        vm.intent = "как сказать спасибо"
        vm.submit()
        try await waitUntil { vm.phase == .results }
        let shown = vm.variants.map(\.en)

        vm.intent = "совсем другой текст"      // edited, never submitted
        vm.screenDisappeared()                  // ← tab switched away

        #expect(vm.intent == "как сказать спасибо")
        #expect(vm.phase == .results)
        #expect(vm.variants.map(\.en) == shown)
    }

    /// With nothing generated there is nothing to mismatch — a draft survives leaving the screen.
    @Test func leavingScreenKeepsDraftWhenNothingGenerated() {
        let vm = makeVM()
        vm.intent = "черновик"
        vm.screenDisappeared()
        #expect(vm.intent == "черновик")
        #expect(vm.phase == .idle)
    }

    /// The chosen mode is persisted: a fresh view model (next launch) starts in the last-used mode.
    @Test func modePersistsAcrossInstances() {
        let vm = makeVM()
        vm.selectMode(.whatToSay)
        #expect(makeVM().mode == .whatToSay)
    }

    /// A ROUTED mode change (widget deep link) applies for the session but must never overwrite the
    /// persisted selector choice — only an explicit on-screen tap does.
    @Test func routedModeIsSessionOnly() {
        let vm = makeVM()
        vm.routeMode(.whatToSay)
        #expect(vm.mode == .whatToSay)          // applied now…
        #expect(makeVM().mode == .howToSay)     // …but the next launch keeps the saved default
    }

    /// A whitespace-only difference (e.g. dictation's trailing space) is NOT an edit — leaving the
    /// screen must not silently rewrite the field.
    @Test func leavingScreenIgnoresWhitespaceOnlyDifference() async throws {
        let vm = makeVM()
        vm.intent = "как сказать спасибо"
        vm.submit()
        try await waitUntil { vm.phase == .results }

        vm.intent = "как сказать спасибо "      // trailing space only
        vm.screenDisappeared()
        #expect(vm.intent == "как сказать спасибо ")   // untouched — not a real edit
    }

    /// Leaving the tab mid-listening must stop the mic WITHOUT auto-submitting: no request may fire
    /// from a screen the user isn't on (stopListening's auto-submit is for the mic button only).
    @Test func leavingScreenStopsListeningWithoutSubmitting() async throws {
        UserDefaults.standard.set(true, forKey: "didPrimeMic")
        let vm = makeVM()
        vm.beginVoiceInput()
        #expect(vm.isListening)

        vm.screenDisappeared()
        #expect(!vm.isListening)
        #expect(vm.phase == .idle)
        try await Task.sleep(for: .milliseconds(100))   // the cancelled capture must not resurface
        #expect(vm.phase == .idle)
        #expect(vm.variants.isEmpty)                    // …and nothing was submitted
    }

    /// Changing the tone with results on screen re-runs the input the results were GENERATED from —
    /// an edited-but-unsubmitted draft is never sent (generation for new text is button-only).
    @Test func toneChangeRerunsGeneratedInputNotDraft() async throws {
        let vm = makeVM()
        vm.intent = "как сказать спасибо"
        vm.submit()
        try await waitUntil { vm.phase == .results }

        vm.intent = "черновик без кнопки"       // edited, never submitted
        vm.selectTone(.formal)
        #expect(vm.intent == "как сказать спасибо")   // draft dropped — the generated input re-runs
        try await waitUntil { vm.phase == .results }
        #expect(vm.phase == .results)
    }

    /// The Say-it Lock Screen widget calls beginVoiceInput on open; it must START the mic (not toggle)
    /// and survive iOS 26's double-delivered deep link — a second call must NOT turn the mic back off.
    @Test func beginVoiceInputStartsMicAndIsIdempotent() {
        UserDefaults.standard.set(true, forKey: "didPrimeMic")   // primed → starts directly, no priming sheet
        let vm = makeVM()
        vm.beginVoiceInput()
        #expect(vm.isListening)                                   // mic on
        vm.beginVoiceInput()                                      // second (double-fire) must be a no-op
        #expect(vm.isListening)
    }

    // MARK: Push-to-talk (capture runs while the button is held; release submits)

    /// Press starts the mic; while held the transcript streams in; RELEASE stops and submits it —
    /// the live-mic contract (the stream stays open until cancelled, unlike the instant mock).
    @Test func holdCapturesAndReleaseSubmits() async throws {
        UserDefaults.standard.set(true, forKey: "didPrimeMic")
        let vm = makeVM(recognizer: HoldingRecognizer(partial: "как сказать спасибо"))
        vm.micPressBegan()
        #expect(vm.isListening)
        try await waitUntil { vm.intent == "как сказать спасибо" }
        #expect(vm.isListening)                                   // still held — no submit yet
        vm.micPressEnded()
        try await waitUntil { vm.phase == .results }
        #expect(vm.phase == .results)
        #expect(!vm.variants.isEmpty)
    }

    /// Releasing with nothing heard must return to idle without firing a request.
    @Test func releaseWithNothingHeardReturnsToIdle() async throws {
        UserDefaults.standard.set(true, forKey: "didPrimeMic")
        let vm = makeVM(recognizer: HoldingRecognizer(partial: nil))
        vm.micPressBegan()
        #expect(vm.isListening)
        vm.micPressEnded()
        #expect(vm.phase == .idle)
        try await Task.sleep(for: .milliseconds(100))             // nothing may resurface later
        #expect(vm.phase == .idle)
        #expect(vm.variants.isEmpty)
    }

    /// A press while the mic is ALREADY on (widget auto-start) must not restart the capture — and
    /// the matching release must still stop and submit, so a tap ends a routed capture.
    @Test func pressDuringRoutedListeningIsNoOpAndReleaseSubmits() async throws {
        UserDefaults.standard.set(true, forKey: "didPrimeMic")
        let vm = makeVM(recognizer: HoldingRecognizer(partial: "как сказать спасибо"))
        vm.beginVoiceInput()                                      // routed (widget): mic on, no finger down
        try await waitUntil { vm.intent == "как сказать спасибо" }
        vm.micPressBegan()                                        // tap lands on the live mic
        #expect(vm.isListening)
        #expect(vm.intent == "как сказать спасибо")               // no restart — transcript survived
        vm.micPressEnded()
        try await waitUntil { vm.phase == .results }
        #expect(vm.phase == .results)
    }

    /// An unprimed press shows the priming sheet (no capture); confirming must NOT auto-start the
    /// mic — the finger is off the button, so an auto-started capture could never be released —
    /// but it MUST go straight on to the system permission prompt (App Review 5.1.1).
    @Test func unprimedPressPrimesWithoutAutoStart() async throws {
        UserDefaults.standard.removeObject(forKey: "didPrimeMic")
        let recognizer = HoldingRecognizer(partial: nil)
        let vm = makeVM(recognizer: recognizer)
        vm.micPressBegan()
        #expect(vm.showMicPriming)
        #expect(!vm.isListening)
        vm.micPressEnded()                                        // release over the sheet: no-op
        #expect(vm.phase == .idle)
        #expect(recognizer.authorizationRequests == 0)            // no system prompt before the message
        vm.confirmPriming()
        #expect(!vm.isListening)                                  // armed, not started
        #expect(UserDefaults.standard.bool(forKey: "didPrimeMic"))
        try await waitUntil { recognizer.authorizationRequests == 1 }
        #expect(recognizer.authorizationRequests == 1)            // system prompt follows at once
    }

    /// The ROUTED priming path is different: the widget promised a hands-free live mic and no
    /// finger was ever involved — confirming the sheet must auto-start the capture.
    @Test func routedPrimingConfirmAutoStarts() {
        UserDefaults.standard.removeObject(forKey: "didPrimeMic")
        let vm = makeVM(recognizer: HoldingRecognizer(partial: nil))
        vm.beginVoiceInput()                                      // widget deep link, unprimed
        #expect(vm.showMicPriming)
        vm.confirmPriming()
        #expect(vm.isListening)                                   // hands-free promise kept
    }

    /// Release must actually SHUT DOWN the capture: the stream is terminated and late audio can't
    /// mutate the input afterwards — a hot-mic regression (submit without stop) fails here.
    @Test func releaseTerminatesCaptureAndIgnoresLateTranscripts() async throws {
        UserDefaults.standard.set(true, forKey: "didPrimeMic")
        let recognizer = HoldingRecognizer(partial: "как сказать спасибо")
        let vm = makeVM(recognizer: recognizer)
        vm.micPressBegan()
        try await waitUntil { vm.intent == "как сказать спасибо" }
        vm.micPressEnded()
        try await waitUntil { recognizer.terminated }
        #expect(recognizer.terminated)                            // the mic is OFF, not just submitted-from
        recognizer.yield("поздний текст")
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.intent == "как сказать спасибо")               // late audio can't touch the input
    }

    /// A SYSTEM cancel of the hold (permission alert, incoming call, scroll claiming the touch)
    /// stops the mic WITHOUT submitting — a truncated utterance must never fire a request.
    @Test func cancelledHoldStopsWithoutSubmitting() async throws {
        UserDefaults.standard.set(true, forKey: "didPrimeMic")
        let recognizer = HoldingRecognizer(partial: "как сказать спасибо")
        let vm = makeVM(recognizer: recognizer)
        vm.micPressBegan()
        try await waitUntil { vm.intent == "как сказать спасибо" }
        vm.micPressCancelled()
        #expect(vm.phase == .idle)
        try await waitUntil { recognizer.terminated }
        #expect(recognizer.terminated)
        try await Task.sleep(for: .milliseconds(100))             // no submit may surface later
        #expect(vm.phase == .idle)
        #expect(vm.variants.isEmpty)
    }

    /// A press while a request is in flight SUPERSEDES it: the old request must not flip the phase
    /// mid-hold (which would swallow the release and leave the mic hot).
    @Test func pressDuringProcessingSupersedesRequest() async throws {
        UserDefaults.standard.set(true, forKey: "didPrimeMic")
        let recognizer = HoldingRecognizer(partial: "как сказать пока")
        let vm = makeVM(llm: StubLLMClient(behavior: .success, latency: .milliseconds(150)),
                        recognizer: recognizer)
        vm.intent = "как сказать спасибо"
        vm.submit()
        #expect(vm.phase == .processing)
        vm.micPressBegan()                                        // press mid-flight
        #expect(vm.isListening)
        try await Task.sleep(for: .milliseconds(300))             // old request would complete by now…
        #expect(vm.isListening)                                   // …but it was cancelled: capture holds the screen
        vm.micPressEnded()
        try await waitUntil { vm.phase == .results }
        #expect(vm.phase == .results)
    }
}

/// A capture stream that behaves like the LIVE mic under push-to-talk: yields a partial (if any)
/// and stays OPEN until the hold ends (task cancellation) — never finishes on its own. Records the
/// termination and allows LATE yields, so tests can assert the release/cancel actually SHUT DOWN
/// the capture (not merely that a submit happened).
private final class HoldingRecognizer: SpeechRecognizing, @unchecked Sendable {
    private let partial: String?
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<SpeechTranscript, Error>.Continuation?
    private var terminatedFlag = false
    private var authorizationRequestCount = 0

    init(partial: String?) { self.partial = partial }

    /// True once the consumer tore the stream down (the mic is OFF).
    var terminated: Bool { lock.lock(); defer { lock.unlock() }; return terminatedFlag }

    /// How many times the system permission prompts were asked for.
    var authorizationRequests: Int { lock.lock(); defer { lock.unlock() }; return authorizationRequestCount }

    func requestAuthorization() async -> Bool {
        lock.withLock { authorizationRequestCount += 1 }
        return true
    }

    /// Simulate audio arriving AFTER the stream was (or should have been) stopped.
    func yield(_ text: String) {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(SpeechTranscript(text: text, isFinal: false))
    }

    func transcribe() -> AsyncThrowingStream<SpeechTranscript, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                self.lock.lock(); self.terminatedFlag = true; self.lock.unlock()
            }
            self.lock.lock(); self.continuation = continuation; self.lock.unlock()
            if let partial = self.partial {
                continuation.yield(SpeechTranscript(text: partial, isFinal: false))
            }
            // No finish: the session ends only via onTermination (release cancels the capture task).
        }
    }
}



// MARK: - Paste affordance (same contract as the Get-it screen)

@Suite(.serialized) @MainActor struct VoiceViewModelPasteTests {

    private func makeVM(pasteboard: any PasteboardReading) -> VoiceViewModel {
        let llm = MockLLMClient()
        let history = MockHistoryRepository()
        let repo = MockExpressionRepository(seed: [])
        return VoiceViewModel(
            howToSay: HowToSayInteractor(llm: llm, history: history),
            regenerateHowToSay: RegenerateHowToSayInteractor(llm: llm, history: history),
            whatToSay: WhatToSayInteractor(llm: llm, history: history),
            voiceCapture: VoiceCaptureInteractor(recognizer: MockSpeechRecognizing()),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            saveExpression: SaveExpressionInteractor(
                enrich: EnrichExpressionInteractor(llm: llm), repository: repo
            ),
            studyList: StudyListInteractor(repository: repo),
            isConfigured: true,
            pasteboard: pasteboard
        )
    }

    @Test func emptyFieldWithClipboardShowsPasteAndPastes() {
        let vm = makeVM(pasteboard: VoiceMockPasteboard(text: "как сказать спасибо"))
        vm.refreshClipboardState()
        #expect(vm.showsPasteAction)
        vm.pasteIntoInput("как сказать спасибо")   // what the system paste control delivers
        #expect(vm.intent == "как сказать спасибо")
        #expect(!vm.showsPasteAction)   // now it's the mode action again
        #expect(vm.phase == .idle)      // paste never auto-submits
    }

    /// A stale has-text signal with nothing usable behind it turns the affordance off.
    @Test func whitespaceClipboardPasteDisarmsAffordance() {
        let vm = makeVM(pasteboard: VoiceMockPasteboard(text: "   "))
        vm.refreshClipboardState()
        #expect(vm.showsPasteAction)
        vm.pasteIntoInput("   ")
        #expect(vm.intent.isEmpty)
        #expect(!vm.showsPasteAction)   // disarmed, not a do-nothing Paste button
    }

    /// Clearing the field re-arms Paste (the didSet refresh path).
    @Test func clearingFieldReArmsPaste() {
        let pasteboard = VoiceMockPasteboard(text: nil)
        let vm = makeVM(pasteboard: pasteboard)
        vm.refreshClipboardState()
        #expect(!vm.showsPasteAction)
        vm.intent = "draft"
        pasteboard.text = "copied later"
        vm.intent = ""                  // ✕ button → didSet re-checks the clipboard
        #expect(vm.showsPasteAction)
    }
}

/// Deterministic canned clipboard for the Say-it Paste affordance tests (mirrors Get it's double).
private final class VoiceMockPasteboard: PasteboardReading, @unchecked Sendable {
    var text: String?
    init(text: String?) { self.text = text }
    var hasText: Bool { text != nil }
}
