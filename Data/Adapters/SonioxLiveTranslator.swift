//
//  SonioxLiveTranslator.swift
//  EnglishHelper — Data (live adapter)
//
//  Live translation over the Soniox real-time WebSocket API (wss://stt-rt.soniox.com), model
//  stt-rt-v5 with built-in one-way translation: ALL recognized speech is translated into the
//  native language in the same stream. Low-latency setup per the official docs: raw pcm_s16le
//  16 kHz mono in ~120 ms binary chunks + the recommended endpoint-detection tuning; partial
//  (non-final) tokens are always on — the pending tail is REPLACED on every server message.
//
//  The session also RECORDS the microphone to an AAC file (SessionRecordings store) so a finished
//  session can be replayed from History, meters input level for the on-button sound diagram, and
//  auto-stops after 5 minutes of continuous silence (Soniox bills wall-clock connection time).
//
//  Lifecycle contract (see the LiveTranslating port): `stop()` = graceful — an empty frame tells
//  Soniox end-of-audio, the final tokens are drained, `.finished(recording:)` is emitted, the
//  stream completes. Cancelling the consuming task = ABORT — teardown, partial recording deleted,
//  nothing emitted. On a mid-session failure the adapter still emits `.finished` (with whatever
//  was recorded) BEFORE throwing, so the use case can save the partial session.
//

import Foundation
import AVFoundation
import AudioToolbox
import OSLog
import Domain

private let liveLog = Logger(subsystem: "tech.10xt.englishhelper", category: "live-translation")

/// Where the Soniox key comes from: a fixed key (development — it ships in the app) or a fresh
/// single-use temporary key from our backend for every WebSocket the session opens (production).
public struct SonioxCredential: Sendable {
    public let isConfigured: Bool
    let key: @Sendable () async throws -> String

    public static func apiKey(_ apiKey: String) -> SonioxCredential {
        SonioxCredential(isConfigured: !apiKey.isEmpty, key: { apiKey })
    }

    public static func temporaryKeys(from backend: BackendSession) -> SonioxCredential {
        SonioxCredential(isConfigured: true, key: { try await backend.sonioxTemporaryKey() })
    }
}

public final class SonioxLiveTranslator: LiveTranslating, @unchecked Sendable {
    public static let defaultEndpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    public static let defaultModel = "stt-rt-v5"

    private let credential: SonioxCredential
    private let model: String
    private let endpoint: URL
    @MainActor private var current: LiveSession?

    public convenience init(apiKey: String, model: String = defaultModel, endpoint: URL = defaultEndpoint) {
        self.init(credential: .apiKey(apiKey), model: model, endpoint: endpoint)
    }

    public init(credential: SonioxCredential, model: String = defaultModel, endpoint: URL = defaultEndpoint) {
        self.credential = credential
        self.model = model
        self.endpoint = endpoint
    }

    public func start(studiedLanguage: String, nativeLanguage: String) -> AsyncThrowingStream<LiveTranslationEvent, Error> {
        let session = LiveSession(credential: credential, model: model, endpoint: endpoint,
                                  studied: studiedLanguage, native: nativeLanguage)
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in session.abort() }
            Task { @MainActor [weak self] in
                // One live session at a time: a stale one (shouldn't happen — the VM guards) is aborted.
                self?.current?.abort()
                self?.current = session
                session.start(yielding: continuation)
            }
        }
    }

    public func setPaused(_ paused: Bool) async {
        let session = await MainActor.run { current }
        await session?.setPaused(paused)
    }

    public func switchLanguages() async {
        let session = await MainActor.run { current }
        await session?.switchLanguages()
    }

    public func stop() async {
        let session = await MainActor.run { current }
        await session?.stopGracefully()
    }
}

// MARK: - Cross-adapter mic signal

/// TRUE while a live session HOLDS the microphone (capturing or paused). The recordings player
/// refuses playback while set — switching the shared AVAudioSession to .playback would kill the
/// capture. An `AVAudioSession.category == .record` check is NOT a substitute: the category
/// lingers as `.record` after deactivation, long after the session ended (which made playback
/// refuse even with no session running). Public only so tests can exercise the player's guard.
public enum LiveMicActivity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active = false

    public static var isActive: Bool { lock.withLock { active } }
    public static func set(_ value: Bool) { lock.withLock { active = value } }
}

// MARK: - Session

/// One live session: mic capture → (converter → WebSocket) + (AAC file), token stream → events.
/// Control state is @MainActor (house style); the realtime audio tap touches only the lock-guarded
/// `TapState` and thread-confined converter/file objects.
private final class LiveSession: @unchecked Sendable {
    private let credential: SonioxCredential
    private let model: String
    private let endpoint: URL
    // `var`: the language-direction toggle swaps these mid-session (socket rotation).
    @MainActor private var studied: String
    @MainActor private var native: String

    // MARK: control state (@MainActor)
    @MainActor private var continuation: AsyncThrowingStream<LiveTranslationEvent, Error>.Continuation?
    @MainActor private var stopped = false          // abort requested or session fully done
    @MainActor private var finishing = false        // graceful stop in progress (draining finals)
    @MainActor private var paused = false           // engine paused; socket kept warm on keepalives
    @MainActor private var rotationPending = false  // language switch: waiting for the old socket's <fin>
    @MainActor private var rotationTimeoutTask: Task<Void, Never>?
    @MainActor private var captureBegan = false
    @MainActor private var didActivateSession = false
    @MainActor private var accumulator = SonioxTokenAccumulator()
    @MainActor private var webSocket: URLSessionWebSocketTask?
    @MainActor private var socketConfigured = false // config frame sent → audio may flow
    @MainActor private var receiveTask: Task<Void, Never>?
    @MainActor private var senderTask: Task<Void, Never>?
    @MainActor private var watchdogTask: Task<Void, Never>?
    @MainActor private var finishTimeoutTask: Task<Void, Never>?
    @MainActor private var interruptionObserver: NSObjectProtocol?
    @MainActor private var configurationObserver: NSObjectProtocol?
    @MainActor private var recordingURL: URL?
    @MainActor private var recordingFileName: String?

    private let engine = AVAudioEngine()
    private let tap = TapState()

    /// Auto-stop after this much continuous silence (user setting: 5 minutes).
    private static let silenceLimit: TimeInterval = 300
    /// 120 ms of 16 kHz mono s16 audio — the chunk cadence from the official examples.
    private static let chunkBytes = 3840
    private static let beginCueID: SystemSoundID = 1113
    private static let endCueID: SystemSoundID = 1114

    init(credential: SonioxCredential, model: String, endpoint: URL, studied: String, native: String) {
        self.credential = credential
        self.model = model
        self.endpoint = endpoint
        self.studied = studied
        self.native = native
    }

    // MARK: start

    func start(yielding continuation: AsyncThrowingStream<LiveTranslationEvent, Error>.Continuation) {
        Task { [self] in
            await MainActor.run { self.continuation = continuation }
            guard credential.isConfigured else {
                await fail(.notConfigured); return
            }
            guard await requestMicPermission() else {
                await fail(.permissionDenied); return
            }
            guard await !isStopped() else { return }
            // Start cue BEFORE the engine: never captured, and its end marks "listening now".
            await Self.playCue(Self.beginCueID)
            await MainActor.run {
                guard !self.stopped else { return }
                do {
                    try self.begin()
                } catch let error as LiveTranslationError {
                    Task { await self.fail(error) }
                } catch {
                    Task { await self.fail(.underlying(error.localizedDescription)) }
                }
            }
        }
    }

    @MainActor
    private func begin() throws {
        // Audio session: same recipe as push-to-talk capture; with UIBackgroundModes=audio this
        // keeps the session alive when the app is backgrounded or the screen locks.
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            didActivateSession = true
        } catch {
            throw LiveTranslationError.underlying("audio session: \(error.localizedDescription)")
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            deactivateSessionIfNeeded()
            throw LiveTranslationError.underlying("no usable microphone input")
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                               channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            deactivateSessionIfNeeded()
            throw LiveTranslationError.underlying("audio converter unavailable")
        }

        // Session recording (AAC .m4a in the recordings store). Best-effort: a file failure must
        // not kill the live session — the user just won't get playback for it.
        let fileName = "live-\(UUID().uuidString).m4a"
        var audioFile: AVAudioFile?
        if let url = RecordingsDirectory.fileURL(named: fileName) {
            audioFile = try? AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: inputFormat.sampleRate,
                    AVNumberOfChannelsKey: Int(inputFormat.channelCount),
                    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                ],
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )
            if audioFile != nil {
                recordingURL = url
                recordingFileName = fileName
            }
        }

        tap.prepare(converter: converter, targetFormat: targetFormat,
                    file: audioFile, inputSampleRate: inputFormat.sampleRate)

        // @Sendable: AVAudioEngine calls this on the realtime audio thread. All touched state is
        // inside the lock-guarded TapState / thread-confined converter+file (see TapState docs).
        let tapState = tap   // TapState is @unchecked Sendable — no nonisolated(unsafe) needed
        let cont = continuation   // AsyncThrowingStream.Continuation is Sendable
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { @Sendable buffer, _ in
            let level = tapState.ingest(buffer)
            cont?.yield(.level(level))
        }

        engine.prepare()
        do {
            try engine.start()
            captureBegan = true
            LiveMicActivity.set(true)   // recordings playback must not steal the session now
        } catch {
            inputNode.removeTap(onBus: 0)
            deactivateSessionIfNeeded()
            throw LiveTranslationError.underlying("audio engine: \(error.localizedDescription)")
        }

        openSocket()
        startSender()
        startWatchdog()
        observeInterruptions()
        continuation?.yield(.listening)
    }

    // MARK: WebSocket

    @MainActor
    private func openSocket() {
        let socket = URLSession.shared.webSocketTask(with: endpoint)
        webSocket = socket
        socket.resume()

        let (credential, model, studied, native) = (credential, model, studied, native)
        receiveTask = Task { [weak self] in
            do {
                // Fetched per socket: a backend temporary key is single-use and lives ~60 s, so a
                // direction rotation needs a fresh one too.
                let config = SonioxSessionConfig(apiKey: try await credential.key(), model: model,
                                                 studied: studied, native: native)
                let data = try JSONEncoder().encode(config)
                try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                await MainActor.run { self?.socketConfigured = true }   // buffered audio may flush now
                await self?.receiveLoop(socket)
            } catch {
                await self?.fail(Self.map(error))
            }
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while true {
            do {
                let message = try await socket.receive()
                guard case .string(let text) = message else { continue }
                guard let payload = text.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(SonioxMessage.self, from: payload) else { continue }

                if let code = decoded.errorCode {
                    liveLog.error("soniox error \(code): \(decoded.errorType ?? "?", privacy: .public)")
                    await fail(Self.map(code: code, type: decoded.errorType))
                    return
                }
                // An EMPTY tokens array still matters: each response's non-final set REPLACES the
                // previous one, so zero tokens = the provisional tail was retracted — clear it.
                if let tokens = decoded.tokens {
                    let snapshot = await MainActor.run { () -> LiveTranslationText in
                        accumulator.ingest(tokens)
                        return accumulator.snapshot
                    }
                    _ = await MainActor.run { continuation?.yield(.text(snapshot)) }   // continuation is MainActor-isolated
                    // A language switch waits for the old socket's finalize marker: everything up
                    // to the switch is now final — rotate. This loop belongs to the OLD socket; end it.
                    if tokens.contains(where: { $0.text == "<fin>" }) {
                        let rotating = await MainActor.run { rotationPending }
                        if rotating {
                            await performRotation()
                            return
                        }
                    }
                }
                if decoded.finished == true {
                    await emitFinishedAndComplete(error: nil)
                    return
                }
            } catch {
                // A rotated-away socket dies by design — only the CURRENT socket's failure matters.
                let (aborted, draining, stale) = await MainActor.run {
                    (stopped, finishing, webSocket !== socket)
                }
                if aborted || stale { return }
                // Socket died while draining finals → finish with what we have instead of failing.
                if draining { await emitFinishedAndComplete(error: nil); return }
                await fail(Self.map(error))
                return
            }
        }
    }

    /// Ships converted audio to the socket every ~100 ms once the config frame is through.
    /// Before that, chunks accumulate in TapState — the official "buffer until configured" tip.
    /// While PAUSED no audio flows — a keepalive every ~10 s stops Soniox's 20 s idle timeout
    /// from closing the warm connection.
    @MainActor
    private func startSender() {
        senderTask = Task { [weak self] in
            var idleCycles = 0
            while let self, !self.isStopped() {
                let (ready, socket, isPaused) = await MainActor.run {
                    (self.socketConfigured, self.webSocket, self.paused)
                }
                if ready, let socket {
                    let chunks = self.tap.take(chunkSize: Self.chunkBytes)
                    if chunks.isEmpty, isPaused {
                        idleCycles += 1
                        if idleCycles >= 100 {   // ~10 s of silence on the wire
                            idleCycles = 0
                            try? await socket.send(.string(#"{"type":"keepalive"}"#))
                        }
                    } else {
                        idleCycles = 0
                    }
                    for chunk in chunks {
                        do { try await socket.send(.data(chunk)) } catch {
                            let draining = await MainActor.run { self.finishing || self.stopped }
                            if !draining { await self.fail(Self.map(error)) }
                            return
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
        }
    }

    // MARK: silence watchdog + interruptions

    @MainActor
    private func startWatchdog() {
        watchdogTask = Task { [weak self] in
            while let self, !self.isStopped() {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { return }
                if Date().timeIntervalSince(self.tap.lastLoudAt) > Self.silenceLimit {
                    liveLog.info("auto-stopping after \(Int(Self.silenceLimit))s of silence")
                    await self.stopGracefully()
                    return
                }
            }
        }
    }

    @MainActor
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .began else { return }
            // A call / Siri took the mic — end the session cleanly so it is saved, not lost.
            Task { await self?.stopGracefully() }
        }
        // A route change (headset unplugged, BT mic died) re-creates the input node's format and
        // STOPS the engine — without handling it the socket would silently starve until the
        // silence watchdog. End the session cleanly instead; the user restarts with one tap.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { await self?.stopGracefully() }
        }
    }

    // MARK: stop / abort / fail

    /// Quick mute/unmute: `AVAudioEngine.pause()` stops the tap callbacks (no audio sent, nothing
    /// recorded, no levels) while the audio session AND the WebSocket stay warm — the sender keeps
    /// the connection alive with keepalives — so resuming is a near-instant `engine.start()`.
    func setPaused(_ newValue: Bool) async {
        await MainActor.run {
            guard captureBegan, !stopped, !finishing, paused != newValue else { return }
            paused = newValue
            if newValue {
                engine.pause()
                continuation?.yield(.level(0))   // flatten the on-button diagram immediately
            } else {
                try? engine.start()
            }
        }
    }

    /// The direction toggle: finalize what the old direction heard, then ROTATE the socket — a new
    /// connection with the languages swapped continues the SAME session (same recording, same
    /// transcripts + a divider line). Audio buffers in TapState during the hand-over, so nothing
    /// said in between is lost.
    func switchLanguages() async {
        await MainActor.run {
            guard captureBegan, !stopped, !finishing, !rotationPending else { return }
            rotationPending = true
            socketConfigured = false   // buffer audio until the NEW socket's config frame is out
            if let socket = webSocket {
                // Flush the old direction's tail into finals; its <fin> marker triggers the rotation.
                Task { try? await socket.send(.string(#"{"type":"finalize"}"#)) }
            }
            // Safety net: rotate even if the <fin> never arrives (dead socket, packet loss).
            rotationTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                await self?.performRotation()
            }
        }
    }

    /// Tear down the drained old socket, swap the languages, draw the divider, reconnect.
    private func performRotation() async {
        await MainActor.run {
            guard rotationPending, !stopped, !finishing else { return }
            rotationPending = false
            rotationTimeoutTask?.cancel()
            rotationTimeoutTask = nil
            receiveTask?.cancel()
            receiveTask = nil
            webSocket?.cancel(with: .goingAway, reason: nil)
            webSocket = nil
            swap(&studied, &native)
            accumulator.insertBoundary()
            continuation?.yield(.text(accumulator.snapshot))
            openSocket()   // new config frame carries the SWAPPED languages
        }
    }

    /// Graceful end: mic off, recording closed, EOF to Soniox, drain finals (5 s cap), emit
    /// `.finished`, complete the stream. Idempotent.
    func stopGracefully() async {
        let alreadyEnding = await MainActor.run { () -> Bool in
            if stopped || finishing { return true }
            finishing = true
            return false
        }
        guard !alreadyEnding else { return }

        await MainActor.run {
            stopCapture()
            // The periodic sender must not race the final flush (out-of-order / post-EOF tail
            // audio): cancel it AND await its in-flight iteration before flushing — cancel alone
            // doesn't abort a send that is already suspended inside URLSession.
            let sender = senderTask
            sender?.cancel()
            senderTask = nil
            // Ship the tail of the audio, then EOF (empty frame). The receive loop keeps running:
            // Soniox finalizes everything and replies … finished:true, which completes the stream.
            let socket = webSocket
            let ready = socketConfigured
            Task { [weak self] in
                guard let self else { return }
                _ = await sender?.value   // strict ordering: only one writer on the socket
                if ready, let socket {
                    for chunk in self.tap.take(chunkSize: Self.chunkBytes, includeRemainder: true) {
                        try? await socket.send(.data(chunk))
                    }
                    try? await socket.send(.data(Data()))           // end-of-audio
                } else {
                    // Socket never came up — nothing to drain.
                    await self.emitFinishedAndComplete(error: nil)
                }
            }
            // Safety net: if the finished frame never arrives, complete anyway.
            finishTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                await self?.emitFinishedAndComplete(error: nil)
            }
        }
    }

    /// Consumer cancelled the stream: hard teardown, discard the partial recording (no history row
    /// will reference it). Also fires after a normal finish — then everything is already done.
    func abort() {
        Task { @MainActor [self] in
            guard !stopped else { return }
            stopped = true
            stopCapture()
            teardownTasks()
            webSocket?.cancel(with: .goingAway, reason: nil)
            webSocket = nil
            // Usually the consumer already terminated the stream (that's what called abort) and
            // this finish is a no-op — but a translator-initiated abort (stale session displaced
            // by a new start) must not leave ITS consumer awaiting forever.
            continuation?.finish()
            continuation = nil
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func fail(_ error: LiveTranslationError) async {
        await emitFinishedAndComplete(error: error)
    }

    /// Single completion chokepoint: close out capture, emit `.finished(recording:)` (also before a
    /// throw, so a partial session can still be saved), then finish the stream and tear down.
    private func emitFinishedAndComplete(error: LiveTranslationError?) async {
        await MainActor.run {
            guard !stopped else { return }
            stopped = true
            stopCapture()   // no-op if the graceful path already did it
            teardownTasks()
            webSocket?.cancel(with: .goingAway, reason: nil)
            webSocket = nil

            let recording: LiveSessionRecording? = recordingFileName.flatMap { name in
                let duration = tap.recordedDuration
                guard duration > 0.5 else {
                    // Nothing meaningful on disk — don't leak a stub file.
                    if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
                    return nil
                }
                return LiveSessionRecording(fileName: name, duration: duration)
            }
            continuation?.yield(.finished(recording: recording))
            if let error {
                continuation?.finish(throwing: error)
            } else {
                continuation?.finish()
            }
            continuation = nil
        }
    }

    @MainActor
    private func stopCapture() {
        guard captureBegan else { return }
        captureBegan = false
        LiveMicActivity.set(false)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        tap.closeFile()
        deactivateSessionIfNeeded()
        AudioServicesPlaySystemSound(Self.endCueID)   // mic is off — tell the user
    }

    @MainActor
    private func teardownTasks() {
        receiveTask?.cancel(); receiveTask = nil
        senderTask?.cancel(); senderTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        finishTimeoutTask?.cancel(); finishTimeoutTask = nil
        rotationTimeoutTask?.cancel(); rotationTimeoutTask = nil
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
    }

    @MainActor
    private func deactivateSessionIfNeeded() {
        guard didActivateSession else { return }
        didActivateSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @MainActor private func isStopped() -> Bool { stopped }

    // MARK: helpers

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in continuation.resume(returning: granted) }
        }
    }

    private static func playCue(_ id: SystemSoundID) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            AudioServicesPlaySystemSoundWithCompletion(id) { done.resume() }
        }
    }

    /// Same "no usable network path" set as ClaudeLLMClient / SonioxClient.
    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
    ]

    private static func map(_ error: Error) -> LiveTranslationError {
        if let backendError = error as? BackendError { return backendError.liveTranslationError }
        if let urlError = error as? URLError {
            if offlineCodes.contains(urlError.code) { return .offline }
            if urlError.code == .timedOut { return .serviceUnavailable }
            return .underlying(urlError.localizedDescription)
        }
        return .underlying(error.localizedDescription)
    }

    private static func map(code: Int, type: String?) -> LiveTranslationError {
        switch code {
        case 401, 403: .unauthorized
        case 402: .balanceExhausted   // "try later" would hide an unrecoverable state
        case 408, 413, 429, 500...: .serviceUnavailable
        default: .underlying(type ?? "error \(code)")
        }
    }
}

// MARK: - Realtime-thread state

/// Everything the audio tap touches. `ingest` runs ON THE REALTIME THREAD: it writes the recording
/// file, converts to 16 kHz s16 mono, appends to the outgoing buffer, and meters level — all state
/// here is either lock-guarded or confined to that single thread (converter/file are only touched
/// by `ingest`, and `closeFile` is called strictly after the engine stopped delivering callbacks).
private final class TapState: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var lastLoud = Date()
    private var framesWritten: Int64 = 0
    private var inputSampleRate: Double = 1

    // Thread-confined to the tap callback (see class doc).
    nonisolated(unsafe) private var converter: AVAudioConverter?
    nonisolated(unsafe) private var targetFormat: AVAudioFormat?
    nonisolated(unsafe) private var file: AVAudioFile?

    private static let loudThreshold: Float = 0.015

    func prepare(converter: AVAudioConverter, targetFormat: AVAudioFormat,
                 file: AVAudioFile?, inputSampleRate: Double) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.file = file
        lock.lock()
        self.inputSampleRate = inputSampleRate
        self.lastLoud = Date()
        lock.unlock()
    }

    /// Returns the input level 0…1 for the sound diagram.
    func ingest(_ buffer: AVAudioPCMBuffer) -> Float {
        try? file?.write(from: buffer)

        // RMS from the first channel (Float32 mic input).
        var rms: Float = 0
        if let channel = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            if n > 0 {
                var sum: Float = 0
                for i in 0..<n { sum += channel[i] * channel[i] }
                rms = (sum / Float(n)).squareRoot()
            }
        }

        var converted = Data()
        if let converter, let targetFormat {
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            if let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) {
                nonisolated(unsafe) var consumed = false
                _ = converter.convert(to: out, error: nil) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                if out.frameLength > 0, let bytes = out.int16ChannelData?[0] {
                    converted = Data(bytes: bytes, count: Int(out.frameLength) * MemoryLayout<Int16>.size)
                }
            }
        }

        lock.lock()
        framesWritten += Int64(buffer.frameLength)
        if rms > Self.loudThreshold { lastLoud = Date() }
        if !converted.isEmpty { pending.append(converted) }
        lock.unlock()

        return min(1, rms * 6)
    }

    /// Drain complete `chunkSize`-byte chunks; `includeRemainder` also drains the final partial
    /// chunk (used once, on graceful stop).
    func take(chunkSize: Int, includeRemainder: Bool = false) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        var chunks: [Data] = []
        while pending.count >= chunkSize {
            chunks.append(Data(pending.prefix(chunkSize)))
            pending.removeFirst(chunkSize)
        }
        if includeRemainder, !pending.isEmpty {
            chunks.append(pending)
            pending = Data()
        }
        return chunks
    }

    var lastLoudAt: Date {
        lock.lock(); defer { lock.unlock() }
        return lastLoud
    }

    var recordedDuration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(framesWritten) / max(1, inputSampleRate)
    }

    /// Called strictly AFTER the engine stopped (no more tap callbacks in flight).
    func closeFile() {
        file = nil   // AVAudioFile finalizes the container on deinit
        converter = nil
    }
}

// MARK: - Wire types

/// Session config — the FIRST (JSON text) frame. Field names match the Soniox WebSocket API;
/// latency knobs follow the docs' "recommended configuration for lower latency".
private struct SonioxSessionConfig: Encodable {
    let apiKey: String
    let model: String
    let studied: String
    let native: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key", model, audioFormat = "audio_format", sampleRate = "sample_rate",
             numChannels = "num_channels", languageHints = "language_hints",
             enableLanguageIdentification = "enable_language_identification",
             enableEndpointDetection = "enable_endpoint_detection",
             endpointLatencyAdjustmentLevel = "endpoint_latency_adjustment_level",
             endpointSensitivity = "endpoint_sensitivity",
             maxEndpointDelayMs = "max_endpoint_delay_ms",
             translation
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encode(model, forKey: .model)
        try c.encode("pcm_s16le", forKey: .audioFormat)
        try c.encode(16000, forKey: .sampleRate)
        try c.encode(1, forKey: .numChannels)
        try c.encode([studied], forKey: .languageHints)
        try c.encode(true, forKey: .enableLanguageIdentification)
        try c.encode(true, forKey: .enableEndpointDetection)
        try c.encode(2, forKey: .endpointLatencyAdjustmentLevel)
        try c.encode(0.3, forKey: .endpointSensitivity)
        try c.encode(1500, forKey: .maxEndpointDelayMs)
        try c.encode(Translation(targetLanguage: native), forKey: .translation)
    }

    struct Translation: Encodable {
        let targetLanguage: String
        enum CodingKeys: String, CodingKey { case type, targetLanguage = "target_language" }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("one_way", forKey: .type)
            try c.encode(targetLanguage, forKey: .targetLanguage)
        }
    }
}

/// Server → client frame: tokens / finished / error (all optional — one frame, three shapes).
struct SonioxMessage: Decodable {
    let tokens: [SonioxToken]?
    let finished: Bool?
    let errorCode: Int?
    let errorType: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code", errorType = "error_type", errorMessage = "error_message"
    }
}

public struct SonioxToken: Decodable, Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    /// "original" | "translation" | "none" (or absent).
    public let translationStatus: String?

    public init(text: String, isFinal: Bool, translationStatus: String? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.translationStatus = translationStatus
    }

    enum CodingKeys: String, CodingKey {
        case text, isFinal = "is_final", translationStatus = "translation_status"
    }
}

/// Pure token → transcript reducer (public for unit tests). Soniox contract: FINAL tokens arrive
/// exactly once and never change — append them; NON-final tokens are a provisional tail that each
/// message REPLACES wholesale. `<end>`/`<fin>` are control markers (endpoint detection / manual
/// finalize): each marks an UTTERANCE BOUNDARY — the next utterance starts a new PARAGRAPH in both
/// transcripts, so a long session reads as speech-shaped paragraphs, not one wall of text.
public struct SonioxTokenAccumulator: Sendable, Equatable {
    public private(set) var originalFinal = ""
    public private(set) var translationFinal = ""
    public private(set) var originalPending = ""
    public private(set) var translationPending = ""

    /// Set on `<end>`/`<fin>`. The break is INSERTED when the next utterance's first final
    /// ORIGINAL token arrives (both panes break together at that moment) — inserting it any
    /// earlier would split the PREVIOUS utterance's still-arriving translation tail, which lags
    /// its speech by a chunk.
    private var paragraphBreakPending = false
    /// A break/boundary was just inserted — trim the leading space off the next token.
    private var trimNextTranslationSpace = false
    private var trimNextOriginalSpace = false

    public init() {}

    /// The visible divider between direction segments (language switch mid-session).
    public static let boundary = "\n\n⸻\n\n"

    /// Language direction switched mid-session: draw a DIVIDER LINE in both transcripts. The
    /// switch is preceded by a finalize, so the pending tails are already flushed — drop them.
    public mutating func insertBoundary() {
        if !originalFinal.isEmpty {
            originalFinal += Self.boundary
            trimNextOriginalSpace = true
        }
        if !translationFinal.isEmpty {
            translationFinal += Self.boundary
            trimNextTranslationSpace = true
        }
        originalPending = ""
        translationPending = ""
        paragraphBreakPending = false
    }

    public mutating func ingest(_ tokens: [SonioxToken]) {
        originalPending = ""
        translationPending = ""
        for token in tokens {
            if token.text == "<end>" || token.text == "<fin>" {
                if !originalFinal.isEmpty { paragraphBreakPending = true }   // never a leading break
                continue
            }
            let isTranslation = token.translationStatus == "translation"
            switch (token.isFinal, isTranslation) {
            case (true, false):
                if paragraphBreakPending {
                    paragraphBreakPending = false
                    originalFinal += "\n\n" + Self.droppingLeadingSpaces(token.text)
                    if !translationFinal.isEmpty {
                        translationFinal += "\n\n"
                        trimNextTranslationSpace = true
                    }
                } else if trimNextOriginalSpace {
                    trimNextOriginalSpace = false
                    originalFinal += Self.droppingLeadingSpaces(token.text)
                } else {
                    originalFinal += token.text
                }
            case (true, true):
                if trimNextTranslationSpace {
                    trimNextTranslationSpace = false
                    translationFinal += Self.droppingLeadingSpaces(token.text)
                } else {
                    translationFinal += token.text
                }
            case (false, false): originalPending += token.text
            case (false, true): translationPending += token.text
            }
        }
        // A provisional tail heard AFTER the boundary already belongs to the NEXT paragraph — show
        // it there. (Translation pending is NOT prefixed: mid-boundary it is usually the tail of
        // the PREVIOUS utterance still being translated.)
        if paragraphBreakPending, !originalPending.isEmpty, !originalFinal.isEmpty {
            originalPending = "\n\n" + Self.droppingLeadingSpaces(originalPending)
        }
    }

    public var snapshot: LiveTranslationText {
        LiveTranslationText(originalFinal: originalFinal, originalPending: originalPending,
                            translationFinal: translationFinal, translationPending: translationPending)
    }

    /// Tokens embed their own leading whitespace — after a paragraph break it must not survive.
    private static func droppingLeadingSpaces(_ text: String) -> String {
        String(text.drop(while: { $0 == " " }))
    }
}
