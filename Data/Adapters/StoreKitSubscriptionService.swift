//
//  StoreKitSubscriptionService.swift
//  EnglishHelper — Data (live adapter for SubscriptionManaging)
//
//  StoreKit 2. An Xcode install (`AppDistribution.local`) is `.unlimited` and never sees a paywall.
//  App Store AND TestFlight builds get the real plan: `.subscribed` while a verified, unrevoked,
//  unexpired transaction for one of `productIDs` exists, else `.free`. TestFlight is included because
//  App Review runs in the same sandbox and can't be told apart from it — the reviewer must see the
//  subscription exactly as a customer does (App Review 2.1(b)); testers subscribe for free there.
//  The backend re-checks the signed data (EntitlementProofs), so this only drives the UI.
//

import Foundation
import StoreKit
import Domain
import os

private let storeLog = Logger(subsystem: "tech.10xt.englishhelper", category: "subscription")

public actor StoreKitSubscriptionService: SubscriptionManaging {
    private let productIDs: [String]
    private var subscribers: [UUID: AsyncStream<AccessTier>.Continuation] = [:]
    private var lastTier: AccessTier?
    private var listener: Task<Void, Never>?

    public init(productIDs: [String]) {
        self.productIDs = productIDs
    }

    /// Starts listening for transactions (purchases on other devices, renewals, refunds, Ask to Buy).
    /// Call once at launch — Apple requires finishing transactions that arrive outside a purchase.
    public func start() {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.publish()
            }
        }
        Task { await publish() }
    }

    // MARK: SubscriptionManaging

    public func currentTier() async -> AccessTier {
        guard Self.offersSubscription else { return .unlimited }
        if let transaction = await activeSubscription()?.transaction {
            return .subscribed(expires: transaction.expirationDate)
        }
        return .free
    }

    public nonisolated func tierUpdates() -> AsyncStream<AccessTier> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.add(id, continuation) }
            continuation.onTermination = { _ in Task { await self.remove(id) } }
        }
    }

    public func restorePurchases() async throws {
        try await AppStore.sync()
        await publish()
    }

    public func refresh() async { await publish() }

    /// Re-reads the store and notifies subscribers if the tier changed (purchase completed, expiry
    /// noticed on foreground, …).
    private func publish() async {
        let tier = await currentTier()
        guard tier != lastTier else { return }
        lastTier = tier
        storeLog.info("access tier: \(String(describing: tier), privacy: .public)")
        for continuation in subscribers.values { continuation.yield(tier) }
    }

    // MARK: Signed evidence for the backend

    public func entitlementProofs() async -> EntitlementProofs {
        let app = try? await AppTransaction.shared
        return EntitlementProofs(appTransaction: app?.jwsRepresentation,
                                 subscription: await activeSubscription()?.jws)
    }

    // MARK: Private

    private func add(_ id: UUID, _ continuation: AsyncStream<AccessTier>.Continuation) async {
        subscribers[id] = continuation
        if let lastTier {
            continuation.yield(lastTier)
        } else {
            continuation.yield(await currentTier())
        }
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }

    /// App Store or TestFlight (incl. App Review) install — anything but an Xcode build.
    private static var offersSubscription: Bool {
        #if DEBUG
        // Paywall / free-plan UI testing from Xcode (whose builds are otherwise always `.unlimited`).
        // The backend still treats Xcode builds as beta — this only changes what the app shows.
        if ProcessInfo.processInfo.arguments.contains("-simulateAppStore") { return true }
        #endif
        return AppDistribution.current != .local
    }

    /// The latest-expiring verified, unrevoked, unexpired subscription transaction.
    private func activeSubscription() async -> (transaction: Transaction, jws: String)? {
        var best: (transaction: Transaction, jws: String)?
        for productID in productIDs {
            for await result in Transaction.currentEntitlements(for: productID) {
                guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
                if let expires = transaction.expirationDate, expires <= Date() { continue }
                if best == nil
                    || (transaction.expirationDate ?? .distantFuture) > (best!.transaction.expirationDate ?? .distantFuture) {
                    best = (transaction, result.jwsRepresentation)
                }
            }
        }
        return best
    }
}
