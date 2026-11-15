//
//  MockLiveTranslation.swift
//  EnglishHelper — Data (mock adapters)
//
//  Deterministic `LiveTranslating` + `SessionRecordingsManaging` for tests/previews/mock boots.
//  The mock session mirrors the live contract: it stays OPEN (like a hot mic) until `stop()` is
//  called, then emits `.finished` and completes — so view-model toggle logic is exercised for real.
//

import Foundation
import Domain

public final class MockLiveTranslating: LiveTranslating, @unchecked Sendable {
    /// Canned behavior for one session.
    public struct Script: Sendable {
        public var updates: [LiveTranslationText]
        public var recording: LiveSessionRecording?
        /// Non-nil = the stream throws AFTER the updates (still emitting `.finished` first,
        /// matching the live adapter's partial-save contract).
        public var failure: LiveTranslationError?

        public init(updates: [LiveTranslationText] = MockLiveTranslating.defaultUpdates,
                    recording: LiveSessionRecording? = LiveSessionRecording(fileName: "mock-session.m4a", duration: 12),
                    failure: LiveTranslationError? = nil) {
            self.updates = updates
            self.recording = recording
            self.failure = failure
        }
    }

    public static let defaultUpdates: [LiveTranslationText] = [
        LiveTranslationText(originalFinal: "", originalPending: "Mind the",
                            translationFinal: "", translationPending: ""),
        LiveTranslationText(originalFinal: "Mind the gap.", originalPending: "",
                            translationFinal: "", translationPending: "Осторожно,"),
        LiveTranslationText(originalFinal: "Mind the gap.", originalPending: "",
                            translationFinal: "Осторожно, промежуток.", translationPending: ""),
    ]

    private let script: Script
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<LiveTranslationEvent, Error>.Continuation?
    private var lastYielded = LiveTranslationText.empty

    /// The languages the LAST start() received — assert direction on this in tests.
    public var lastStartLanguages: (studied: String, native: String)? {
        lock.withLock { startLanguages }
    }
    private var startLanguages: (studied: String, native: String)?

    /// How many times the direction was switched mid-session.
    public var switchCount: Int {
        lock.withLock { switches }
    }
    private var switches = 0

    public init(script: Script = Script()) {
        self.script = script
    }

    public func start(studiedLanguage: String, nativeLanguage: String) -> AsyncThrowingStream<LiveTranslationEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            self.startLanguages = (studiedLanguage, nativeLanguage)
            self.lastYielded = script.updates.last ?? .empty
            lock.unlock()
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuation = nil
                self.lock.unlock()
            }
            continuation.yield(.listening)
            continuation.yield(.level(0.4))
            for update in script.updates { continuation.yield(.text(update)) }
            if let failure = script.failure {
                continuation.yield(.finished(recording: script.recording))
                continuation.finish(throwing: failure)
            }
            // Otherwise stay open — the "mic" keeps listening until stop().
        }
    }

    /// Last requested pause state — assert on this in tests.
    public var isPaused: Bool {
        lock.withLock { paused }
    }
    private var paused = false

    public func setPaused(_ newValue: Bool) async {
        lock.withLock { paused = newValue }
    }

    /// Mirrors the live adapter's contract: mid-session a divider line lands in both transcripts.
    public func switchLanguages() async {
        let (continuation, updated) = lock.withLock { () -> (AsyncThrowingStream<LiveTranslationEvent, Error>.Continuation?, LiveTranslationText) in
            switches += 1
            let boundary = SonioxTokenAccumulator.boundary
            lastYielded = LiveTranslationText(
                originalFinal: lastYielded.originalFinal.isEmpty ? "" : lastYielded.originalFinal + boundary,
                originalPending: "",
                translationFinal: lastYielded.translationFinal.isEmpty ? "" : lastYielded.translationFinal + boundary,
                translationPending: ""
            )
            return (self.continuation, lastYielded)
        }
        continuation?.yield(.text(updated))
    }

    public func stop() async {
        let continuation = lock.withLock {
            let held = self.continuation
            self.continuation = nil
            self.paused = false
            return held
        }
        continuation?.yield(.finished(recording: script.recording))
        continuation?.finish()
    }
}

public final class MockSessionRecordings: SessionRecordingsManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var existing: Set<String>
    private var deletedNames: [String] = []
    /// When each recording was created; one without a date is as old as can be.
    private let createdAt: [String: Date]

    public init(existing: Set<String> = [], createdAt: [String: Date] = [:]) {
        self.existing = existing
        self.createdAt = createdAt
    }

    /// Names passed to `delete` — assert on this in tests.
    public var deleted: [String] {
        lock.lock(); defer { lock.unlock() }
        return deletedNames
    }

    public func exists(fileName: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return existing.contains(fileName)
    }

    public func delete(fileName: String) async {
        lock.withLock {
            existing.remove(fileName)
            deletedNames.append(fileName)
        }
    }

    public func sweep(keeping: Set<String>, createdBefore: Date) async {
        lock.withLock {
            let orphaned = existing.subtracting(keeping)
                .filter { (createdAt[$0] ?? .distantPast) < createdBefore }
            existing.subtract(orphaned)
            deletedNames.append(contentsOf: orphaned.sorted())
        }
    }

    public func play(fileName: String) -> AsyncThrowingStream<RecordingPlayback, Error> {
        let known = exists(fileName: fileName)
        return AsyncThrowingStream { continuation in
            guard known else {
                continuation.finish(throwing: RecordingPlaybackError.missing)
                return
            }
            continuation.yield(.playing(progress: 0.5))
            continuation.yield(.finished)
            continuation.finish()
        }
    }
}
