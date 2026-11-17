//
//  BackgroundTime.swift
//  EnglishHelper — Domain (port)
//
//  A short stretch of running time the app asks the system for when it is about to lose its reason
//  to run behind the screen — a live session whose microphone has just gone off still has its last
//  words to collect and its History row to write. Without it the system may suspend the app in the
//  middle (and a suspended app can be discarded: the session's text would be gone). The platform
//  work (a background-task assertion) lives in the App layer.
//

import Foundation

public protocol BackgroundTimeHolding: Sendable {
    /// Asks for the time. The returned closure gives it back — call it once the work is done (the
    /// system reclaims the time by itself after a short while, half a minute or so, if it isn't).
    func hold(_ name: String) async -> @Sendable () async -> Void
}
