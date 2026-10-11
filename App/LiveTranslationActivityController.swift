//
//  LiveTranslationActivityController.swift
//  EnglishHelper — App
//
//  The ActivityKit side of `LiveSessionActivityPresenting`: keeps ONE Live Activity in step with
//  the running online-translation session, so the Lock Screen shows a Voice-Memos-style banner
//  (recording indicator + elapsed time + pause/stop) while the phone is locked mid-session.
//  Lives in the App layer — the composition root is the only place that touches ActivityKit;
//  Presentation sees only the protocol. All calls are best-effort: Live Activities being disabled
//  (Settings → Gist It) must never affect the session itself.
//

import Foundation
import ActivityKit
import Presentation

@MainActor
final class LiveTranslationActivityController: LiveSessionActivityPresenting {
    private var activity: Activity<LiveTranslationActivityAttributes>?
    private var startedAt = Date()
    private var direction = ""
    private var isPaused = false

    init() {
        // A crash / force-quit mid-session can leave a stale banner on the Lock Screen with no
        // session behind it — clear any survivors at boot (constructed once, from AppContainer).
        Task {
            for stale in Activity<LiveTranslationActivityAttributes>.activities {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func sessionStarted(direction: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        self.direction = direction
        isPaused = false
        // A rotated socket can re-announce listening on the SAME session — update, don't stack a
        // second banner.
        if activity != nil { push(); return }
        startedAt = Date()
        activity = try? Activity.request(
            attributes: LiveTranslationActivityAttributes(),
            content: ActivityContent(state: state, staleDate: nil)
        )
    }

    func sessionPaused(_ isPaused: Bool) {
        self.isPaused = isPaused
        push()
    }

    func directionChanged(_ direction: String) {
        self.direction = direction
        push()
    }

    func sessionEnded() {
        guard let activity else { return }
        self.activity = nil
        let box = ActivityBox(activity)
        let final = state
        Task { await box.value.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate) }
    }

    private var state: LiveTranslationActivityAttributes.ContentState {
        .init(isPaused: isPaused, startedAt: startedAt, direction: direction)
    }

    private func push() {
        guard let activity else { return }
        let box = ActivityBox(activity)
        let state = state
        Task { await box.value.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// `Activity` isn't Sendable and stays reachable through `self.activity`, so region analysis
    /// can't transfer it into the update/end Tasks. ActivityKit's update/end are documented safe
    /// to call from any context — the box just carries the reference across.
    private struct ActivityBox: @unchecked Sendable {
        let value: Activity<LiveTranslationActivityAttributes>
        init(_ value: Activity<LiveTranslationActivityAttributes>) { self.value = value }
    }
}
