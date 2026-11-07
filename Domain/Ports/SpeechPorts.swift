//
//  SpeechPorts.swift
//  EnglishHelper — Domain (ports)
//
//  Long-lived extension points. Each expresses ONLY domain intent — no AVFoundation / Speech /
//  URLSession types in any signature — and must be satisfiable by BOTH an on-device AND a cloud
//  backend without changing the protocol. Async + cancellation + failure are first-class.
//

import Foundation

// MARK: - Speech recognition (RU audio → transcript)

/// A progressively-refined transcript chunk.
public struct SpeechTranscript: Sendable, Equatable {
    public let text: String
    /// `true` once recognition has settled on the final result.
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Recognizes spoken Russian into text.
///
/// Backend note: Apple `Speech` (on-device) today, a cloud STT (e.g. Whisper) tomorrow —
/// both capture/stream internally, so the port takes no audio buffers.
public protocol SpeechRecognizing: Sendable {
    /// Begin a recognition session. The stream yields partial transcripts and a final one,
    /// then finishes. Cancel the consuming `Task` to stop and release the microphone.
    /// Fails with `SpeechRecognitionError`.
    func transcribe() -> AsyncThrowingStream<SpeechTranscript, Error>

    /// Ask for the access `transcribe()` needs (microphone, speech recognition), showing the system
    /// prompts if the user hasn't decided yet. Returns whether capture is allowed.
    func requestAuthorization() async -> Bool
}

extension SpeechRecognizing {
    /// Backends (and test doubles) that need no permission.
    public func requestAuthorization() async -> Bool { true }
}

// MARK: - Speech synthesis (EN text → playback)

/// Playback state for synthesized speech.
public enum SpeechPlaybackState: Sendable, Equatable {
    case preparing
    case speaking(progress: Double)   // 0...1
    case finished
}

/// Speaks English text aloud, reporting playback state.
///
/// Backend note: `AVSpeechSynthesizer` today, ElevenLabs cloud TTS tomorrow.
public protocol SpeechSynthesizing: Sendable {
    /// Speak `text`, yielding state updates until playback finishes. Cancel the `Task` to stop.
    /// Fails with `SpeechSynthesisError`.
    func speak(_ text: String) -> AsyncThrowingStream<SpeechPlaybackState, Error>
}
