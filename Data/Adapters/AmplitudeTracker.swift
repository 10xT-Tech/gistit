//
//  AmplitudeTracker.swift
//  EnglishHelper — Data (live analytics adapter)
//
//  The ONLY place in the codebase that touches the Amplitude SDK (enforced by
//  ForbiddenImportTests for Domain/Presentation). Events go to the Amplitude "GistIt" project
//  (EU data center — the org lives on app.eu.amplitude.com). No ATT/IDFA (the Swift SDK never
//  reads it), so there is no tracking-consent prompt anywhere in the app. We send bare event
//  names only (see `AnalyticsEvent`) — never user content; the SDK adds sessions + app-lifecycle
//  events (installed / updated / opened / backgrounded) on its own.
//

import Foundation
import Domain
import AmplitudeSwift

/// `@unchecked Sendable`: `Amplitude` isn't annotated, but its public API is thread-safe (every
/// call is funneled onto the SDK's internal serial queues).
public final class AmplitudeTracker: AnalyticsTracking, @unchecked Sendable {

    private let amplitude: Amplitude

    /// Create ONCE per process, at the app entry point: the SDK starts its session / lifecycle
    /// observers on init, and two instances with the same name would share (and race on) storage.
    public init(apiKey: String) {
        amplitude = Amplitude(configuration: AmplitudeSwift.Configuration(
            apiKey: apiKey,
            serverZone: .EU,
            autocapture: [.sessions, .appLifecycles]
        ))
        // Every event (autocaptured lifecycle ones included) carries the build channel + build
        // number; `app_version` (CFBundleShortVersionString) is set by the SDK itself. Mirrored as
        // user properties so cohorts / user lookups can split by channel too.
        let distribution = AppDistribution.current.rawValue
        let build = AppDistribution.buildNumber
        amplitude.add(plugin: BuildContextPlugin(distribution: distribution, build: build))
        amplitude.identify(identify: Identify()
            .set(property: Self.distributionKey, value: distribution)
            .set(property: Self.buildKey, value: build))
    }

    static let distributionKey = "environment"
    static let buildKey = "app_build"

    /// Fire-and-forget: `track` only enqueues; batching, persistence and retries happen on the
    /// SDK's queues — analytics can't slow down or fail a use case.
    public func track(_ event: Domain.AnalyticsEvent) {   // qualified: AmplitudeCore has its own AnalyticsEvent
        amplitude.track(eventType: event.rawValue)
    }
}

/// Stamps `environment` (production / testflight / local) and `app_build` on every event.
private final class BuildContextPlugin: EnrichmentPlugin, @unchecked Sendable {
    private let distribution: String
    private let build: String

    init(distribution: String, build: String) {
        self.distribution = distribution
        self.build = build
    }

    override func execute(event: BaseEvent) -> BaseEvent? {
        var properties = event.eventProperties ?? [:]
        properties[AmplitudeTracker.distributionKey] = distribution
        properties[AmplitudeTracker.buildKey] = build
        event.eventProperties = properties
        return event
    }
}
