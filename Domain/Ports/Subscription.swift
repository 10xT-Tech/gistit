//
//  Subscription.swift
//  EnglishHelper — Domain
//
//  The user's access plan. Backend-agnostic: the Data adapter decides it from the App Store
//  (StoreKit); the backend enforces the same rules server-side, so this drives UX only.
//

import Foundation

public enum AccessTier: Sendable, Equatable {
    /// Everything unlocked, no paywall: TestFlight / Xcode builds, or a development build that talks
    /// to the services directly. The subscription only exists in the App Store version.
    case unlimited
    /// App Store build with an active subscription.
    case subscribed(expires: Date?)
    /// App Store build without one: translations are unlimited; explanations and Say it share one
    /// request per 5 minutes (whatever the model); live translation is unavailable.
    case free

    public var hasUnlimitedExplanations: Bool { self != .free }
    public var canUseLiveTranslation: Bool { self != .free }
    /// Whether the app should offer the subscription at all.
    public var offersSubscription: Bool { self != .unlimited }
}

public protocol SubscriptionManaging: Sendable {
    /// The current plan (re-read from the store).
    func currentTier() async -> AccessTier
    /// Emits the plan now and whenever it changes (purchase, renewal, expiry, refund).
    func tierUpdates() -> AsyncStream<AccessTier>
    /// Re-reads the store and notifies `tierUpdates` if the plan changed (after a purchase, on foreground).
    func refresh() async
    /// Re-syncs purchases with the App Store ("Restore purchases").
    func restorePurchases() async throws
}

/// Development / tests: everything unlocked.
public struct UnlimitedAccess: SubscriptionManaging {
    public init() {}
    public func currentTier() async -> AccessTier { .unlimited }
    public func tierUpdates() -> AsyncStream<AccessTier> {
        AsyncStream { $0.yield(.unlimited); $0.finish() }
    }
    public func refresh() async {}
    public func restorePurchases() async throws {}
}
