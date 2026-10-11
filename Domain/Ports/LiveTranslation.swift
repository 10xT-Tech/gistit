//
//  LiveTranslation.swift
//  EnglishHelper — Domain (ports)
//
//  Online translation: the phone listens to surrounding speech (studied language) and streams a
//  live translation (native language). Backend-agnostic — the port leaks no audio/transport types;
//  the live adapter (Soniox WebSocket) owns the microphone, the cloud session, and the on-disk
//  session recording. A companion port plays back / deletes stored session recordings.
//

import Foundation

/// The rolling transcript of a live session. `…Final` text is committed and only ever grows;
/// `…Pending` is the provisional tail that is REPLACED on every update as more audio arrives.
public struct LiveTranslationText: Sendable, Equatable {
    public let originalFinal: String
    public let originalPending: String
    public let translationFinal: String
    public let translationPending: String

    public init(originalFinal: String = "", originalPending: String = "",
                translationFinal: String = "", translationPending: String = "") {
        self.originalFinal = originalFinal
        self.originalPending = originalPending
        self.translationFinal = translationFinal
        self.translationPending = translationPending
    }

    public static let empty = LiveTranslationText()
}

/// The audio recording of a finished live session, stored by the adapter's recordings store.
public struct LiveSessionRecording: Sendable, Equatable {
    /// File name inside the recordings store (NOT a path — the container path changes across
    /// reinstalls, so history rows must never persist absolute URLs).
    public let fileName: String
    public let duration: TimeInterval

    public init(fileName: String, duration: TimeInterval) {
        self.fileName = fileName
        self.duration = duration
    }
}

public enum LiveTranslationEvent: Sendable, Equatable {
    /// The session is live: socket open, microphone hot.
    case listening
    /// New transcript state (full snapshot, not a delta).
    case text(LiveTranslationText)
    /// Microphone input level 0…1 (a few times per second) — drives the on-button sound diagram.
    case level(Float)
    /// The session ended gracefully (user stop, silence auto-stop, interruption). Always the last
    /// event before the stream finishes; `recording` is nil when nothing could be recorded.
    case finished(recording: LiveSessionRecording?)
}

public enum LiveTranslationError: Error, Sendable, Equatable {
    case permissionDenied      // microphone access refused
    case notConfigured         // no API key
    case unauthorized          // the service rejected the key
    case balanceExhausted      // the service account has no funds — retrying can't help
    case offline
    case serviceUnavailable    // server-side failure / overload / rate limit
    case subscriptionRequired  // live translation is a subscriber feature
    case underlying(String)
}

/// One live listening session at a time. Cancel the consuming task to ABORT (nothing is saved);
/// call `stop()` for a GRACEFUL end (remaining text is drained, `.finished` is emitted, then the
/// stream completes).
public protocol LiveTranslating: Sendable {
    /// Start listening. `studiedLanguage`/`nativeLanguage` are ISO-639-1 codes ("en", "ru").
    /// The stream throws `LiveTranslationError` on session failure.
    func start(studiedLanguage: String, nativeLanguage: String) -> AsyncThrowingStream<LiveTranslationEvent, Error>
    /// Quickly MUTE/UNMUTE the running session: while paused, recognition and the recording stop,
    /// but the session stays warm (connection kept alive) so resuming is instant. No-op when no
    /// session is running. The silence auto-stop keeps counting — a forgotten paused session still
    /// ends (and saves) itself.
    func setPaused(_ paused: Bool) async
    /// Swap the recognition/translation direction MID-SESSION: the current tail is finalized, a
    /// separator line is appended to both transcripts, and the stream continues with the languages
    /// reversed — same session, same recording. No-op when no session is running (the next start
    /// simply receives the languages the caller wants).
    func switchLanguages() async
    /// Gracefully end the current session (no-op when none is running).
    func stop() async
}

// MARK: - Stored session recordings (playback from History)

public enum RecordingPlayback: Sendable, Equatable {
    case playing(progress: Double)   // 0…1
    case finished
}

public enum RecordingPlaybackError: Error, Sendable, Equatable {
    case missing                     // the file is gone (deleted / never recorded)
    case busy                        // the microphone is live (an online session is running)
    case underlying(String)
}

/// Playback + lifecycle of stored session recordings. File names come from
/// `RequestResult.liveTranslation(audioFileName:)`.
public protocol SessionRecordingsManaging: Sendable {
    /// Play a stored recording; yields progress. Cancel the consuming task to stop playback.
    /// Throws `.busy` while a live session holds the microphone — playback must never steal it.
    func play(fileName: String) -> AsyncThrowingStream<RecordingPlayback, Error>
    /// Whether the recording file still exists (drives the play button in History).
    func exists(fileName: String) -> Bool
    /// Best-effort removal of the recording file (called when its history row is deleted).
    func delete(fileName: String) async
    /// Remove every stored recording NOT in `keeping` — reconciles the store against history
    /// (crashes mid-session, the in-memory fallback store, and skipped saves all orphan files).
    func sweep(keeping: Set<String>) async
}
