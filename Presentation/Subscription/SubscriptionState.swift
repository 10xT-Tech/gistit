//
//  SubscriptionState.swift
//  EnglishHelper — Presentation
//
//  The user's plan for the UI: whether to show the paywall, gate Online mode, and what Settings says.
//  The backend enforces the same rules, so this is never the only line of defence.
//

import Foundation
import Observation
import Domain

@MainActor
@Observable
public final class SubscriptionState {
    /// `.unlimited` until the store answers — no paywall flashes up in TestFlight / Xcode builds.
    public private(set) var tier: AccessTier = .unlimited
    public let productID: String
    public let privacyPolicyURL: URL
    public let termsOfUseURL: URL
    /// Outcome of the last "Restore purchases", shown under the button.
    public private(set) var restoreMessage: String?
    public private(set) var isRestoring = false

    private let service: any SubscriptionManaging
    private var isListening = false

    public init(service: any SubscriptionManaging = UnlimitedAccess(),
                productID: String = "",
                privacyPolicyURL: URL = URL(string: "https://example.com")!,
                termsOfUseURL: URL = URL(string: "https://example.com")!) {
        self.service = service
        self.productID = productID
        self.privacyPolicyURL = privacyPolicyURL
        self.termsOfUseURL = termsOfUseURL
    }

    /// Follows plan changes for the life of the app. Idempotent.
    public func start() async {
        guard !isListening else { return }
        isListening = true
        for await tier in service.tierUpdates() { self.tier = tier }
    }

    /// Re-read the store (after a purchase, when the app returns to the foreground).
    public func refresh() async {
        await service.refresh()
    }

    public func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await service.restorePurchases()
            await service.refresh()
            restoreMessage = tier == .free
                ? Loc.t("Активная подписка не найдена.", "No active subscription found.")
                : Loc.t("Подписка восстановлена.", "Subscription restored.")
        } catch {
            restoreMessage = Loc.t("Не удалось связаться с App Store. Попробуйте позже.",
                                   "Couldn't reach the App Store. Try again later.")
        }
    }
}
