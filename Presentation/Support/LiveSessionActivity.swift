//
//  LiveSessionActivity.swift
//  EnglishHelper — Presentation (support)
//
//  Port for the Lock Screen presence of a RUNNING online-translation session (the Live Activity
//  banner with the recording indicator and pause/stop buttons). A protocol so InViewModel stays
//  free of ActivityKit and unit-testable with a spy; the real implementation lives in the App
//  layer (`LiveTranslationActivityController`), which is the only place that touches ActivityKit.
//

import Foundation

/// The banner's lifecycle, driven by InViewModel's live-session state changes.
@MainActor
public protocol LiveSessionActivityPresenting: AnyObject {
    /// The session actually started listening (mic + socket up) — show the banner.
    func sessionStarted(direction: String)
    /// Pause toggled — flip the indicator and the pause/resume button.
    func sessionPaused(_ isPaused: Bool)
    /// The direction toggle rotated a running session — update the banner's label.
    func directionChanged(_ direction: String)
    /// The session ended (stopped, failed, or auto-stopped) — remove the banner.
    func sessionEnded()
}

/// Commands arriving FROM the Live Activity buttons. Their intents run in the app's process and
/// post these; InViewModel observes them. Raw values are duplicated as literals in
/// Shared/LiveTranslationActivity.swift (that file can't import Presentation) — keep in sync.
public extension Notification.Name {
    static let liveTranslationPauseCommand = Notification.Name("tech.10xt.englishhelper.live.pauseCommand")
    static let liveTranslationStopCommand = Notification.Name("tech.10xt.englishhelper.live.stopCommand")
}
