//
//  PaywallView.swift
//  EnglishHelper — Presentation
//
//  The monthly subscription offer. StoreKit's own SubscriptionStoreView renders the price, period,
//  purchase button, Restore Purchases and the Terms / Privacy links (all required by App Review),
//  localized by the App Store; the marketing header above it is ours.
//

import SwiftUI
import StoreKit
import DesignSystem

public struct PaywallView: View {
    @Environment(SubscriptionState.self) private var subscription
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        SubscriptionStoreView(productIDs: [subscription.productID]) {
            header
        }
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.visible, for: .cancellation)
        .subscriptionStorePolicyDestination(url: subscription.termsOfUseURL, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: subscription.privacyPolicyURL, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, result in
            // A custom handler replaces StoreKit's default one, so finishing the transaction is ours.
            guard case .success(.success(let verification)) = result else { return }
            if case .verified(let transaction) = verification { await transaction.finish() }
            await subscription.refresh()
            dismiss()
        }
        .tint(Tokens.Content.primary)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s16) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Tokens.Content.primary)
                .accessibilityHidden(true)
            Text(Loc.t("Gist It Pro", "Gist It Pro"))
                .textStyle(Tokens.Text.largeTitle)
                .foregroundStyle(Tokens.Content.primary)
            VStack(alignment: .leading, spacing: Tokens.Space.s12) {
                feature("lightbulb", Loc.t("Объяснения и «Сказать» без ограничений — слова, фразы и фото.",
                                           "Unlimited explanations and Say it — words, phrases and photos."))
                feature("waveform", Loc.t("Онлайн-перевод: живой переводчик речи вокруг вас.",
                                          "Online translation: a live interpreter for the speech around you."))
                feature("character.bubble", Loc.t("Перевод остаётся бесплатным для всех.",
                                                  "Translation stays free for everyone."))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.Space.s20)
        .padding(.top, Tokens.Space.s24)
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s12) {
            Image(systemName: symbol)
                .foregroundStyle(Tokens.Content.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .textStyle(Tokens.Text.body)
                .foregroundStyle(Tokens.Content.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
