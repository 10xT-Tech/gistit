//
//  LiveTranslationTests.swift
//  EnglishHelperTests
//
//  Online translation: the Soniox token reducer, the session→history use case, the swipe-delete
//  path (row + audio file), and the new history kind's coding stability.
//

import Testing
import Foundation
import Domain
import Adapters
import Presentation

// MARK: - Token accumulator (pure reducer over the Soniox stream contract)

struct SonioxTokenAccumulatorTests {

    @Test func finalsAccumulateAndPendingIsReplaced() {
        var acc = SonioxTokenAccumulator()
        acc.ingest([
            SonioxToken(text: "Hel", isFinal: false, translationStatus: "original"),
            SonioxToken(text: "lo", isFinal: false, translationStatus: "original"),
        ])
        #expect(acc.originalPending == "Hello")
        // Next message: the earlier non-finals are superseded — part becomes final, tail changes.
        acc.ingest([
            SonioxToken(text: "Hello", isFinal: true, translationStatus: "original"),
            SonioxToken(text: " wor", isFinal: false, translationStatus: "original"),
        ])
        #expect(acc.originalFinal == "Hello")
        #expect(acc.originalPending == " wor")
        // A message with no non-finals clears the pending tail entirely.
        acc.ingest([SonioxToken(text: " world", isFinal: true, translationStatus: "original")])
        #expect(acc.originalFinal == "Hello world")
        #expect(acc.originalPending.isEmpty)
    }

    @Test func translationTokensRouteToTheirOwnBuffers() {
        var acc = SonioxTokenAccumulator()
        acc.ingest([
            SonioxToken(text: "Good", isFinal: true, translationStatus: "original"),
            SonioxToken(text: "Хорошо", isFinal: true, translationStatus: "translation"),
            SonioxToken(text: " же", isFinal: false, translationStatus: "translation"),
            SonioxToken(text: " day", isFinal: false, translationStatus: "none"),   // untranslated speech = original side
        ])
        #expect(acc.originalFinal == "Good")
        #expect(acc.originalPending == " day")
        #expect(acc.translationFinal == "Хорошо")
        #expect(acc.translationPending == " же")
    }

    /// A language switch draws a divider line in BOTH transcripts and drops the flushed tails;
    /// the first tokens после разделителя lose their leading space.
    @Test func boundaryDrawsDividerInBothTranscripts() {
        var acc = SonioxTokenAccumulator()
        acc.ingest([
            SonioxToken(text: "Hello", isFinal: true, translationStatus: "original"),
            SonioxToken(text: "Привет", isFinal: true, translationStatus: "translation"),
        ])
        acc.insertBoundary()
        acc.ingest([
            SonioxToken(text: " Да", isFinal: true, translationStatus: "original"),
            SonioxToken(text: " Yes", isFinal: true, translationStatus: "translation"),
        ])
        #expect(acc.originalFinal == "Hello\(SonioxTokenAccumulator.boundary)Да")
        #expect(acc.translationFinal == "Привет\(SonioxTokenAccumulator.boundary)Yes")
    }

    @Test func markerTokensAreFiltered() {
        var acc = SonioxTokenAccumulator()
        acc.ingest([
            SonioxToken(text: "Done", isFinal: true, translationStatus: "original"),
            SonioxToken(text: "<end>", isFinal: true, translationStatus: nil),
            SonioxToken(text: "<fin>", isFinal: true, translationStatus: nil),
        ])
        #expect(acc.originalFinal == "Done")
        #expect(acc.snapshot == LiveTranslationText(originalFinal: "Done"))
    }

    /// An `<end>` boundary starts a new PARAGRAPH in both transcripts — inserted when the next
    /// utterance's speech is finalized, so the previous utterance's translation tail stays whole.
    @Test func endpointBoundaryStartsNewParagraphsInBothPanes() {
        var acc = SonioxTokenAccumulator()
        acc.ingest([
            SonioxToken(text: "Hello.", isFinal: true, translationStatus: "original"),
            SonioxToken(text: "Привет.", isFinal: true, translationStatus: "translation"),
            SonioxToken(text: "<end>", isFinal: true, translationStatus: nil),
        ])
        // Translation TAIL of utterance 1 arriving after <end> still joins its own paragraph.
        acc.ingest([SonioxToken(text: " Ещё.", isFinal: true, translationStatus: "translation")])
        #expect(acc.translationFinal == "Привет. Ещё.")

        // The next utterance's first finalized speech triggers the break in BOTH panes,
        // with the tokens' leading spaces stripped after the break.
        acc.ingest([
            SonioxToken(text: " How", isFinal: true, translationStatus: "original"),
            SonioxToken(text: " are you?", isFinal: true, translationStatus: "original"),
            SonioxToken(text: " Как", isFinal: true, translationStatus: "translation"),
        ])
        #expect(acc.originalFinal == "Hello.\n\nHow are you?")
        #expect(acc.translationFinal == "Привет. Ещё.\n\nКак")
    }

    /// A provisional (pending) tail heard after the boundary renders in the NEXT paragraph;
    /// a boundary before any text never produces a leading break.
    @Test func pendingAfterBoundaryRendersAsNewParagraph() {
        var acc = SonioxTokenAccumulator()
        acc.ingest([SonioxToken(text: "<end>", isFinal: true, translationStatus: nil)])
        #expect(acc.originalFinal.isEmpty)   // no leading break at session start
        acc.ingest([
            SonioxToken(text: "One.", isFinal: true, translationStatus: "original"),
            SonioxToken(text: "<end>", isFinal: true, translationStatus: nil),
        ])
        acc.ingest([SonioxToken(text: " Two", isFinal: false, translationStatus: "original")])
        #expect(acc.originalFinal == "One.")
        #expect(acc.originalPending == "\n\nTwo")
    }
}

// MARK: - Session → history use case

@MainActor struct LiveTranslateUseCaseTests {

    private func waitUntil(_ condition: () async -> Bool, timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while await !condition() {
            if clock.now - start > timeout { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A stopped session lands in history with the full text (finals + pending tail) and recording.
    @Test func gracefulStopSavesSessionToHistory() async throws {
        let history = MockHistoryRepository()
        let live = MockLiveTranslating(script: .init(
            updates: [LiveTranslationText(originalFinal: "Mind the gap.", originalPending: " Please",
                                          translationFinal: "Осторожно, промежуток.", translationPending: "")],
            recording: LiveSessionRecording(fileName: "s1.m4a", duration: 42)
        ))
        let useCase = LiveTranslateInteractor(live: live, history: history)

        let consumer = Task {
            for try await _ in useCase.start(studiedLanguage: "en", nativeLanguage: "ru") {}
        }
        try await Task.sleep(for: .milliseconds(50))   // let the updates flow
        await useCase.stop()
        _ = try? await consumer.value

        let entries = try await history.recent(limit: 10)
        #expect(entries.count == 1)
        guard case .liveTranslation(let original, let ru, let file, let duration) = entries.first?.result else {
            Issue.record("expected a liveTranslation entry, got \(String(describing: entries.first))")
            return
        }
        #expect(original == "Mind the gap. Please")   // pending tail is kept — it's the best estimate
        #expect(ru == "Осторожно, промежуток.")
        #expect(file == "s1.m4a")
        #expect(duration == 42)
    }

    /// Nothing recognized → nothing in history (no empty rows for accidental taps) — and the
    /// session's recording is deleted, not orphaned on disk with no row referencing it.
    @Test func emptySessionIsNotSavedAndItsRecordingIsDeleted() async throws {
        let history = MockHistoryRepository()
        let recordings = MockSessionRecordings(existing: ["noise.m4a"])
        let live = MockLiveTranslating(script: .init(
            updates: [], recording: LiveSessionRecording(fileName: "noise.m4a", duration: 8)
        ))
        let useCase = LiveTranslateInteractor(live: live, history: history, recordings: recordings)

        let consumer = Task {
            for try await _ in useCase.start(studiedLanguage: "en", nativeLanguage: "ru") {}
        }
        try await Task.sleep(for: .milliseconds(50))
        await useCase.stop()
        _ = try? await consumer.value

        let entries = try await history.recent(limit: 10)
        #expect(entries.isEmpty)
        #expect(recordings.deleted == ["noise.m4a"])
    }

    /// A mid-session failure still saves the partial session (the adapter emits `.finished` first).
    @Test func failedSessionStillSavesPartialText() async throws {
        let history = MockHistoryRepository()
        let live = MockLiveTranslating(script: .init(
            updates: [LiveTranslationText(originalFinal: "Hello", translationFinal: "Привет")],
            recording: nil,
            failure: .serviceUnavailable
        ))
        let useCase = LiveTranslateInteractor(live: live, history: history)

        var thrown: Error?
        do {
            for try await _ in useCase.start(studiedLanguage: "en", nativeLanguage: "ru") {}
        } catch { thrown = error }
        #expect(thrown as? LiveTranslationError == .serviceUnavailable)

        try await waitUntil { (try? await history.recent(limit: 10))?.isEmpty == false }
        let entries = try await history.recent(limit: 10)
        #expect(entries.count == 1)
        guard case .liveTranslation(let original, let ru, let file, _) = entries.first?.result else {
            Issue.record("expected a liveTranslation entry"); return
        }
        #expect(original == "Hello")
        #expect(ru == "Привет")
        #expect(file == nil)
    }
}

// MARK: - History delete (row + audio) and coding

struct LiveHistoryTests {

    @Test func liveTranslationSurvivesCodingRoundTrip() throws {
        let result = RequestResult.liveTranslation(original: "Hello there", ru: "Привет",
                                                   audioFileName: "live-abc.m4a", duration: 12.5)
        let decoded = try JSONDecoder().decode(RequestResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
        #expect(decoded.kind == .liveTranslation)
        // nil audio must also round-trip (recording can be absent).
        let noAudio = RequestResult.liveTranslation(original: "a", ru: "б", audioFileName: nil, duration: 0)
        let decoded2 = try JSONDecoder().decode(RequestResult.self, from: JSONEncoder().encode(noAudio))
        #expect(decoded2 == noAudio)
    }

    @Test func deleteRemovesRowAndItsRecording() async throws {
        let history = MockHistoryRepository()
        let recordings = MockSessionRecordings(existing: ["s2.m4a"])
        let entry = HistoryEntry(inputText: "Hi",
                                 result: .liveTranslation(original: "Hi", ru: "Привет",
                                                          audioFileName: "s2.m4a", duration: 3))
        try await history.append(entry)
        try await history.append(HistoryEntry(inputText: "bank", result: .translate(ru: "банк")))

        let useCase = RequestHistoryInteractor(history: history, recordings: recordings)
        try await useCase.delete(entry)

        let remaining = try await history.recent(limit: 10)
        #expect(remaining.count == 1)
        #expect(remaining.first?.kind == .translate)
        #expect(recordings.deleted == ["s2.m4a"])   // the audio went with the row

        // A text-only entry deletes without touching the recordings store.
        try await useCase.delete(remaining[0])
        #expect(recordings.deleted == ["s2.m4a"])
        let empty = try await history.recent(limit: 10)
        #expect(empty.isEmpty)
    }
}

// MARK: - Recordings playback guard

struct SessionRecordingsPlayerTests {

    /// The player refuses playback ONLY while a live session actually holds the mic — never
    /// because the shared audio session's category still lingers from an ENDED session.
    @Test func playbackBusyOnlyWhileLiveMicIsActive() async {
        let player = SessionRecordingsPlayer()

        LiveMicActivity.set(true)
        defer { LiveMicActivity.set(false) }
        var thrown: Error?
        do {
            for try await _ in player.play(fileName: "whatever.m4a") {}
        } catch { thrown = error }
        #expect(thrown as? RecordingPlaybackError == .busy)

        // Mic released (session over) → the guard opens; a nonexistent file now reports .missing,
        // proving the request got PAST the busy check.
        LiveMicActivity.set(false)
        thrown = nil
        do {
            for try await _ in player.play(fileName: "whatever.m4a") {}
        } catch { thrown = error }
        #expect(thrown as? RecordingPlaybackError == .missing)
    }
}

// MARK: - InViewModel online mode

@Suite(.serialized) @MainActor struct InViewModelOnlineTests {

    init() {
        UserDefaults.standard.removeObject(forKey: "getItMode")
        UserDefaults.standard.set(true, forKey: "didPrimeMic")
        UserDefaults.standard.set("english", forKey: "studiedLanguage")
        UserDefaults.standard.set("russian", forKey: "targetLanguage")
    }

    private func makeVM(
        live: any LiveTranslating = MockLiveTranslating(),
        history: MockHistoryRepository = MockHistoryRepository(),
        liveActivity: (any LiveSessionActivityPresenting)? = nil
    ) -> InViewModel {
        let llm = MockLLMClient()
        let repo = MockExpressionRepository(seed: [])
        return InViewModel(
            understand: UnderstandInteractor(llm: llm, history: history),
            explain: ExplainExpressionInteractor(llm: llm),
            voiceCapture: VoiceCaptureInteractor(recognizer: MockSpeechRecognizing()),
            liveTranslate: LiveTranslateInteractor(live: live, history: history),
            pronounce: PlayPronunciationInteractor(synthesizer: MockSpeechSynthesizing()),
            saveExpression: SaveExpressionInteractor(
                enrich: EnrichExpressionInteractor(llm: llm), repository: repo
            ),
            studyList: StudyListInteractor(repository: repo),
            isConfigured: true,
            pasteboard: EmptyPasteboard(),
            liveActivity: liveActivity
        )
    }

    private func waitUntil(_ condition: () async -> Bool, timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while await !condition() {
            if clock.now - start > timeout { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func toggleStartsAndStopsAndSavesHistory() async throws {
        let history = MockHistoryRepository()
        let vm = makeVM(history: history)
        vm.routeMode(.online)   // session-only: never persists getItMode under a parallel suite

        vm.toggleLive()
        #expect(vm.isLiveListening)
        try await waitUntil { vm.liveText.translationFinal == "Осторожно, промежуток." }
        #expect(vm.liveText.originalFinal == "Mind the gap.")

        vm.toggleLive()   // second tap = graceful stop
        try await waitUntil { !vm.isLiveListening }
        #expect(!vm.isLiveListening)
        #expect(vm.liveText.originalFinal == "Mind the gap.")   // transcript stays on screen

        try await waitUntil { (try? await history.recent(limit: 5))?.isEmpty == false }
        let entries = try await history.recent(limit: 5)
        #expect(entries.first?.kind == .liveTranslation)
    }

    /// Switching away from Online mid-session ends it gracefully — never a hot mic under
    /// another mode's screen.
    @Test func leavingOnlineModeStopsTheSession() async throws {
        let vm = makeVM()
        vm.routeMode(.online)   // session-only: never persists getItMode under a parallel suite
        vm.toggleLive()
        #expect(vm.isLiveListening)

        vm.routeMode(.translate)
        try await waitUntil { !vm.isLiveListening }
        #expect(!vm.isLiveListening)
    }

    /// First-ever mic use in Online mode primes first; confirming starts the session (a toggle tap
    /// has no held finger, so — unlike push-to-talk — priming resumes the start).
    @Test func unprimedTogglePrimesThenConfirmStarts() async throws {
        UserDefaults.standard.removeObject(forKey: "didPrimeMic")
        defer { UserDefaults.standard.set(true, forKey: "didPrimeMic") }
        let vm = makeVM()
        vm.routeMode(.online)   // session-only: never persists getItMode under a parallel suite

        vm.toggleLive()
        #expect(vm.showMicPriming)
        #expect(!vm.isLiveListening)

        vm.confirmPriming()
        #expect(vm.isLiveListening)
    }

    /// Pause mutes the running session (passed through to the port) WITHOUT ending it; a second
    /// tap resumes just as fast.
    @Test func pauseTogglesQuicklyWithoutEndingTheSession() async throws {
        let live = MockLiveTranslating()
        let vm = makeVM(live: live)
        vm.routeMode(.online)
        vm.toggleLive()
        #expect(vm.isLiveListening)

        vm.toggleLivePause()
        #expect(vm.isLivePaused)
        try await waitUntil { live.isPaused }
        #expect(live.isPaused)
        #expect(vm.isLiveListening)          // still running — pause is not stop

        vm.toggleLivePause()
        try await waitUntil { !live.isPaused }
        #expect(!vm.isLivePaused)
        #expect(vm.isLiveListening)
    }

    /// "New" saves the running session to History (with its recording) and clears the screen;
    /// the drain tail never repopulates the cleared panes.
    @Test func newSavesCurrentSessionAndClearsTheScreen() async throws {
        let history = MockHistoryRepository()
        let vm = makeVM(history: history)
        vm.routeMode(.online)
        vm.toggleLive()
        try await waitUntil { vm.liveText.translationFinal == "Осторожно, промежуток." }

        vm.newLiveSession()
        #expect(vm.liveText == .empty)       // cleared immediately
        try await waitUntil { !vm.isLiveListening }
        #expect(vm.liveText == .empty)       // the finishing session's tail stayed out

        try await waitUntil { (try? await history.recent(limit: 5))?.isEmpty == false }
        let entries = try await history.recent(limit: 5)
        #expect(entries.first?.kind == .liveTranslation)   // the previous session WAS saved
    }

    /// Direction toggle while IDLE: only the setting flips — nothing is sent to the port, and the
    /// next start listens in the reversed direction (native → studied).
    @Test func directionToggleWhileIdleOnlyChangesTheSetting() async throws {
        UserDefaults.standard.set("english", forKey: "studiedLanguage")
        UserDefaults.standard.set("russian", forKey: "targetLanguage")
        let live = MockLiveTranslating()
        let vm = makeVM(live: live)
        vm.routeMode(.online)

        #expect(!vm.isLiveReversed)              // default: studied → native
        vm.toggleLiveDirection()
        #expect(vm.isLiveReversed)
        #expect(live.switchCount == 0)           // idle: no mid-session switch happened

        vm.toggleLive()                          // the NEXT session starts reversed
        try await waitUntil { live.lastStartLanguages != nil }
        #expect(live.lastStartLanguages?.studied == "ru")   // now LISTENING to the native language
        #expect(live.lastStartLanguages?.native == "en")
    }

    /// Direction toggle on a RUNNING session: passed through to the port, which draws a divider
    /// line in both transcripts and continues — the session never stops.
    @Test func directionToggleWhileListeningDrawsDividerAndContinues() async throws {
        let live = MockLiveTranslating()
        let vm = makeVM(live: live)
        vm.routeMode(.online)
        vm.toggleLive()
        try await waitUntil { vm.liveText.translationFinal == "Осторожно, промежуток." }

        vm.toggleLiveDirection()
        #expect(vm.isLiveReversed)
        try await waitUntil { live.switchCount == 1 }
        #expect(live.switchCount == 1)
        try await waitUntil { vm.liveText.originalFinal.contains("⸻") }
        #expect(vm.liveText.originalFinal.contains("⸻"))      // divider in the speech pane
        #expect(vm.liveText.translationFinal.contains("⸻"))   // …and in the translation pane
        #expect(vm.isLiveListening)                            // still the same session
    }

    @Test func submitIsANoOpInOnlineMode() async throws {
        let vm = makeVM()
        vm.routeMode(.online)   // session-only: never persists getItMode under a parallel suite
        vm.source = "bank"
        vm.submit()
        #expect(vm.phase == .idle)   // no request fired
    }

    /// The Lock Screen widget's hands-free start: begins a session and is IDEMPOTENT — iOS 26 can
    /// deliver the widget URL twice, and the second delivery must never stop the first's session.
    @Test func beginLiveInputStartsSessionAndIsIdempotent() async throws {
        let vm = makeVM()
        vm.routeMode(.online)   // session-only: never persists getItMode under a parallel suite
        vm.beginLiveInput()
        #expect(vm.isLiveListening)
        vm.beginLiveInput()      // duplicate URL delivery
        #expect(vm.isLiveListening)   // still listening — NOT toggled off
        try await waitUntil { vm.liveText.originalFinal == "Mind the gap." }
        #expect(vm.liveText.originalFinal == "Mind the gap.")
    }

    /// Unprimed mic: the widget-routed start primes first; confirming resumes the session start.
    @Test func beginLiveInputPrimesThenConfirmStarts() async throws {
        UserDefaults.standard.removeObject(forKey: "didPrimeMic")
        defer { UserDefaults.standard.set(true, forKey: "didPrimeMic") }
        let vm = makeVM()
        vm.routeMode(.online)
        vm.beginLiveInput()
        #expect(vm.showMicPriming)
        #expect(!vm.isLiveListening)
        vm.confirmPriming()
        #expect(vm.isLiveListening)
    }

    /// The Live Activity mirrors the session lifecycle: banner up when listening actually starts
    /// (with the direction label), pause/resume and direction flips pushed as updates, banner down
    /// when the session ends.
    @Test func liveActivityFollowsSessionLifecycle() async throws {
        let spy = SpyLiveActivity()
        let vm = makeVM(liveActivity: spy)
        vm.routeMode(.online)
        vm.toggleLive()
        try await waitUntil { spy.events.first == "start EN → RU" }
        #expect(spy.events == ["start EN → RU"])

        vm.toggleLivePause()
        #expect(spy.events.last == "paused")
        vm.toggleLivePause()
        #expect(spy.events.last == "resumed")

        vm.toggleLiveDirection()
        #expect(spy.events.last == "direction RU → EN")

        vm.toggleLive()   // graceful stop → stream finishes → banner comes down
        try await waitUntil { spy.events.last == "end" }
        #expect(spy.events.last == "end")
    }

    /// A session that FAILS mid-run must still take the banner down — a dead session may not keep
    /// a live "recording" indicator on the Lock Screen.
    @Test func liveActivityEndsOnFailure() async throws {
        let spy = SpyLiveActivity()
        let vm = makeVM(live: MockLiveTranslating(script: .init(failure: .underlying("boom"))),
                        liveActivity: spy)
        vm.routeMode(.online)
        vm.toggleLive()
        try await waitUntil { spy.events.last == "end" }
        #expect(spy.events.last == "end")
        #expect(!vm.isLiveListening)
    }

    /// The Live Activity buttons: their intents post command notifications from the app process;
    /// the view model must act on them — pause toggles, stop ends (and stop while idle is a no-op).
    @Test func liveActivityCommandsControlTheSession() async throws {
        let vm = makeVM()
        vm.routeMode(.online)

        // Stop while idle: must NOT start a session (unlike the Listen toggle).
        NotificationCenter.default.post(name: .liveTranslationStopCommand, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!vm.isLiveListening)

        vm.toggleLive()
        try await waitUntil { vm.isLiveListening }

        NotificationCenter.default.post(name: .liveTranslationPauseCommand, object: nil)
        try await waitUntil { vm.isLivePaused }
        #expect(vm.isLivePaused)

        NotificationCenter.default.post(name: .liveTranslationStopCommand, object: nil)
        try await waitUntil { !vm.isLiveListening }
        #expect(!vm.isLiveListening)
    }
}

/// Records the Live Activity calls the view model makes (the ActivityKit controller lives in the
/// App layer and can't run under unit tests).
@MainActor
private final class SpyLiveActivity: LiveSessionActivityPresenting {
    var events: [String] = []
    func sessionStarted(direction: String) { events.append("start \(direction)") }
    func sessionPaused(_ isPaused: Bool) { events.append(isPaused ? "paused" : "resumed") }
    func directionChanged(_ direction: String) { events.append("direction \(direction)") }
    func sessionEnded() { events.append("end") }
}

/// Deterministic empty clipboard (never reads the simulator's real one).
private struct EmptyPasteboard: PasteboardReading {
    var hasText: Bool { false }
}
