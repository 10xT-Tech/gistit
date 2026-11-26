//
//  Prefs.swift
//  EnglishHelper — Presentation
//
//  The UserDefaults store for user preferences the view models WRITE (screen modes, tone, permission
//  priming). Normally `.standard`; under XCUITest (`-uiTestStubs`) an ephemeral suite wiped on every
//  launch — so test taps never pollute the real app's saved preferences on that simulator, and every
//  test launch starts clean (`-uiTestKeepPrefs` skips the wipe: a relaunch inside one test, for what
//  must survive it — the last screen, a chosen mode). READS still see the test's pinned `-key value` launch arguments either
//  way, because the argument domain heads the search list of every UserDefaults instance.
//

import Foundation

enum Prefs {
    /// `nonisolated(unsafe)`: UserDefaults is documented thread-safe; the SDK just doesn't mark it
    /// Sendable. The `let` itself is initialized once (static-let guarantee) and never reassigned.
    nonisolated(unsafe) static let store: UserDefaults = {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestStubs") else { return .standard }
        let suite = "tech.10xt.englishhelper.uitests"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        // `-uiTestKeepPrefs`: a RELAUNCH inside one test — what the launch before it wrote is still there.
        if !ProcessInfo.processInfo.arguments.contains("-uiTestKeepPrefs") {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }()
}
