//
//  ShareButton.swift
//  EnglishHelper — DesignSystem
//
//  Share a phrase / translation / explanation to other apps and messengers through the system share
//  sheet. Sits next to `CopyButton` on every card that can be copied and shares exactly the text Copy
//  would put on the clipboard. Same two styles and sizes as CopyButton. The sheet is presented with
//  UIKit (`ShareSheetPresenter`) rather than `ShareLink`, so cards that fold their buttons into one
//  accessibility element can offer the same "Share" as a VoiceOver action.
//

import SwiftUI
import UIKit

public struct ShareButton: View {
    public enum Style { case labeled, icon }

    private let text: String
    private let style: Style
    private let accessibilityName: String?

    /// - Parameters:
    ///   - text: the string handed to the share sheet.
    ///   - style: `.labeled` (icon + word) or `.icon` (icon only).
    ///   - accessibilityLabel: spoken label (defaults to "Share").
    public init(_ text: String, style: Style = .icon, accessibilityLabel: String? = nil) {
        self.text = text
        self.style = style
        self.accessibilityName = accessibilityLabel
    }

    public var body: some View {
        Button { ShareSheetPresenter.share(text) } label: {
            switch style {
            case .labeled:
                Label(DSLoc.t("Поделиться", "Share"), systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(Tokens.Content.secondary)
            case .icon:
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                    .foregroundStyle(Tokens.Content.tertiary)
            }
        }
        .buttonStyle(.plain)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(accessibilityName ?? DSLoc.t("Поделиться", "Share"))
    }
}

/// Presents the system share sheet for a piece of text from wherever the user is (sheets included).
@MainActor public enum ShareSheetPresenter {
    public static func share(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let presenter = topViewController() else { return }
        let sheet = UIActivityViewController(activityItems: [trimmed], applicationActivities: nil)
        // Required on iPad-sized layouts (popover); harmless on iPhone.
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
        presenter.present(sheet, animated: true)
    }

    /// The front-most view controller of the active window (walks presented sheets).
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
