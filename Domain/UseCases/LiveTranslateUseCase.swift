//
//  LiveTranslateUseCase.swift
//  EnglishHelper — Domain (use case)
//
//  "Get it" Online mode: stream a live listening session (mic → cloud STT + translation) and, when
//  the session ends, record it in history — original text, translation, and the audio recording —
//  so it can be revisited (and replayed) later.
//

import Foundation

public protocol LiveTranslateUseCase: Sendable {
    /// Start a live session; forwards the port's event stream. `studiedLanguage`/`nativeLanguage`
    /// are ISO-639-1 codes ("en", "ru").
    func start(studiedLanguage: String, nativeLanguage: String) -> AsyncThrowingStream<LiveTranslationEvent, Error>
    /// Quickly mute/unmute the running session (see `LiveTranslating.setPaused`).
    func setPaused(_ paused: Bool) async
    /// Set the running session's direction (see `LiveTranslating.setLanguages`).
    func setLanguages(studiedLanguage: String, nativeLanguage: String) async
    /// Gracefully end the current session (drains remaining text; the stream then completes).
    func stop() async
}

public struct LiveTranslateInteractor: LiveTranslateUseCase {
    private let live: any LiveTranslating
    private let history: HistoryRepository
    /// For deleting the recording of a session that ISN'T saved (nothing recognized) — otherwise
    /// the file is orphaned forever. Nil in lean test setups.
    private let recordings: (any SessionRecordingsManaging)?
    private let analytics: (any AnalyticsTracking)?
    /// Keeps the app running from the moment a session starts to end until its History row is
    /// written. Behind the screen the microphone was the app's reason to run: once it is off the
    /// system may suspend the app while the last words are still coming, and a suspended app can be
    /// discarded — with the whole session's text. Nil in tests.
    private let background: (any BackgroundTimeHolding)?

    public init(live: any LiveTranslating, history: HistoryRepository,
                recordings: (any SessionRecordingsManaging)? = nil,
                analytics: (any AnalyticsTracking)? = nil,
                background: (any BackgroundTimeHolding)? = nil) {
        self.live = live
        self.history = history
        self.recordings = recordings
        self.analytics = analytics
        self.background = background
    }

    public func start(studiedLanguage: String, nativeLanguage: String) -> AsyncThrowingStream<LiveTranslationEvent, Error> {
        let upstream = live.start(studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
        let history = self.history
        let recordings = self.recordings
        let analytics = self.analytics
        let background = self.background
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Track the latest snapshot so the finished session can be logged even when the
                // stream ends with an error (the adapter emits .finished before failing when it
                // has anything to save).
                var lastText = LiveTranslationText.empty
                var recording: LiveSessionRecording?
                var sawFinish = false
                var releaseBackgroundTime: (@Sendable () async -> Void)?

                /// From the first sign of the end (`.ending`; `.finished` when the session failed at
                /// once) until the session is saved.
                func holdBackgroundTime() async {
                    guard releaseBackgroundTime == nil else { return }
                    releaseBackgroundTime = await background?.hold("live-session.save")
                }

                func saveIfMeaningful() async {
                    guard sawFinish else { return }   // aborted (task cancelled) sessions are discarded
                    // Pending (provisional) tails are included: on an abrupt end they are the best
                    // remaining estimate of what was said, and are never followed by a correction.
                    let original = (lastText.originalFinal + lastText.originalPending)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let translation = (lastText.translationFinal + lastText.translationPending)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !original.isEmpty || !translation.isEmpty else {
                        // Nothing heard → no history row; the recording (background noise) must
                        // not stay on disk with no row referencing it.
                        if let fileName = recording?.fileName { await recordings?.delete(fileName: fileName) }
                        return
                    }
                    // Best-effort, like every other history append.
                    try? await history.append(HistoryEntry(
                        inputText: original,
                        result: .liveTranslation(original: original, ru: translation,
                                                 audioFileName: recording?.fileName,
                                                 duration: recording?.duration ?? 0)
                    ))
                    analytics?.track(.liveTranslationCompleted)
                }

                do {
                    for try await event in upstream {
                        switch event {
                        case .text(let text): lastText = text
                        case .ending: await holdBackgroundTime()
                        case .cutShort(let part):
                            analytics?.track(part == .sending ? .liveTailNotSent : .liveTailNotAnswered)
                        case .finished(let rec):
                            recording = rec
                            sawFinish = true
                            await holdBackgroundTime()
                        case .listening, .level: break
                        }
                        continuation.yield(event)
                    }
                    await saveIfMeaningful()
                    await releaseBackgroundTime?()
                    continuation.finish()
                } catch {
                    await saveIfMeaningful()
                    await releaseBackgroundTime?()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func setPaused(_ paused: Bool) async { await live.setPaused(paused) }

    public func setLanguages(studiedLanguage: String, nativeLanguage: String) async {
        await live.setLanguages(studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
    }

    public func stop() async { await live.stop() }
}
