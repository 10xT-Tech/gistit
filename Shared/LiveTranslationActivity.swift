//
//  LiveTranslationActivity.swift
//  EnglishHelper — Shared (compiled into the APP and the LockWidgets extension — this file only,
//  not the whole Shared/ folder)
//
//  The Live Activity contract for a running online-translation session: the attributes/state the
//  Lock Screen banner renders, and the pause/stop intents behind its buttons. Both sides of the
//  process boundary need the SAME type names and Codable layout, so this single file is compiled
//  into both targets (the standard ActivityKit setup when the types don't live in a shared
//  framework — LockWidgets deliberately links no app frameworks).
//
//  The buttons work with the app backgrounded/locked because the intents conform to
//  `LiveActivityIntent`: the system runs `perform()` INSIDE the app's process (alive during a
//  session thanks to the audio background mode), where it posts a command notification that
//  InViewModel observes. The notification names are string literals here because this file cannot
//  import Presentation — they MUST match `Notification.Name.liveTranslationPauseCommand` /
//  `.liveTranslationStopCommand` in Presentation/Support/LiveSessionActivity.swift.
//

import Foundation
import ActivityKit
import AppIntents

public struct LiveTranslationActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        /// Session muted via Pause — drives the indicator (red record ↔ orange pause) and the
        /// pause/resume button glyph.
        public var isPaused: Bool
        /// When the session started listening — the banner's elapsed-time text ticks from it
        /// on its own (no updates needed).
        public var startedAt: Date
        /// Human direction label, e.g. "EN → RU". Updated when the direction toggle rotates
        /// the session.
        public var direction: String

        public init(isPaused: Bool, startedAt: Date, direction: String) {
            self.isPaused = isPaused
            self.startedAt = startedAt
            self.direction = direction
        }
    }

    public init() {}
}

/// Pause ↔ resume the running session from the Live Activity button.
public struct ToggleLiveTranslationPauseIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Pause or resume live translation"

    public init() {}

    public func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: Notification.Name("tech.10xt.englishhelper.live.pauseCommand"), object: nil)
        return .result()
    }
}

/// Gracefully stop the running session from the Live Activity button (it saves to History,
/// exactly like the in-app Listen toggle).
public struct StopLiveTranslationIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Stop live translation"

    public init() {}

    public func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: Notification.Name("tech.10xt.englishhelper.live.stopCommand"), object: nil)
        return .result()
    }
}
