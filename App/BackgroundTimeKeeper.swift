//
//  BackgroundTimeKeeper.swift
//  EnglishHelper — App
//
//  App-side `BackgroundTimeHolding`: a UIKit background-task assertion. A live session that ends
//  behind the screen (Stop on the Lock Screen, the silence auto-stop, a phone call) turns its
//  microphone off first — and with it the app's reason to run there — while the last words are still
//  to be collected and the session written to History. The assertion bridges those seconds.
//

import UIKit
import Domain

final class BackgroundTimeKeeper: BackgroundTimeHolding {
    func hold(_ name: String) async -> @Sendable () async -> Void {
        let task = await MainActor.run { Assertion(name: name) }
        return { await MainActor.run { task.end() } }
    }

    /// One assertion; ended once — by its holder, or by the system reclaiming the time.
    @MainActor
    private final class Assertion {
        private var id: UIBackgroundTaskIdentifier = .invalid

        init(name: String) {
            id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                self?.end()   // out of time: the assertion must be released, or the app is killed
            }
        }

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
