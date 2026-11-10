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
    /// App Store / TestFlight build without one. Everything on the device is free — flashcards with
    /// any goal, the lists, the duplicate search and exact merges, card files. What calls the model:
    /// translations unlimited; explanations, Say it, cards from photos and Fix cards share one request
    /// per 5 minutes (the backend meters them); live translation and the model's duplicate check
    /// unavailable.
    case free

    public var hasUnlimitedExplanations: Bool { self != .free }
    public var canUseLiveTranslation: Bool { self != .free }
    /// The model's duplicate check (Find duplicates → Check).
    public var canCheckDuplicates: Bool { self != .free }
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
