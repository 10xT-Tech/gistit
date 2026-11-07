//
//  SpeechUseCases.swift
//  EnglishHelper — Domain (use cases)
//
//  Thin wrappers over the speech ports so Presentation consumes USE CASES only and never imports
//  Speech/AVFoundation. Streams + cancellation pass straight through.
//

import Foundation

/// Capture spoken Russian → live transcript stream.
public protocol VoiceCaptureUseCase: Sendable {
    func callAsFunction() -> AsyncThrowingStream<SpeechTranscript, Error>
    /// Show the system permission prompts now (right after the in-app explanation).
    func requestAuthorization() async -> Bool
}

public struct VoiceCaptureInteractor: VoiceCaptureUseCase {
    private let recognizer: SpeechRecognizing
    public init(recognizer: SpeechRecognizing) { self.recognizer = recognizer }
    public func callAsFunction() -> AsyncThrowingStream<SpeechTranscript, Error> {
        recognizer.transcribe()
    }
    public func requestAuthorization() async -> Bool {
        await recognizer.requestAuthorization()
    }
}

/// Play an English phrase aloud → playback-state stream.
public protocol PlayPronunciationUseCase: Sendable {
    func callAsFunction(_ text: String) -> AsyncThrowingStream<SpeechPlaybackState, Error>
}

public struct PlayPronunciationInteractor: PlayPronunciationUseCase {
    private let synthesizer: SpeechSynthesizing
    public init(synthesizer: SpeechSynthesizing) { self.synthesizer = synthesizer }
    public func callAsFunction(_ text: String) -> AsyncThrowingStream<SpeechPlaybackState, Error> {
        synthesizer.speak(text)
    }
}
