//
//  Subscription.swift
//  EnglishHelper — Domain
//
//  The user's access plan. Backend-agnostic: the Data adapter decides it from the App Store
//  (StoreKit); the backend enforces the same rules server-side, so this drives UX only.
//

import Foundation

public enum AccessTier: Sendable, Equatable {
    /// Everything unlocked, no paywall: Xcode builds, or a development build that talks to the
    /// services directly. TestFlight gets the real plan — App Review runs there and must see the offer.
    case unlimited
    /// App Store / TestFlight build with an active subscription.
    case subscribed(expires: Date?)
    /// App Store / TestFlight build without one: translations are unlimited; explanations and Say it
    /// share one request per 5 minutes (whatever the model); flashcards `freeDailyCards` a day (no
    /// goal of one's own, no extra sets); live translation, Fix cards and Find duplicates unavailable.
    case free

    /// Flashcards a day on the free plan — the goal, whatever Settings say.
    public static let freeDailyCards = 25

    public var hasUnlimitedExplanations: Bool { self != .free }
    public var canUseLiveTranslation: Bool { self != .free }
    /// A daily goal of one's own and extra sets past it (flashcards are on-device: the app is the only gate).
    public var canStudyUnlimited: Bool { self != .free }
    /// Fix cards and Find duplicates.
    public var canUseCardTools: Bool { self != .free }
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
