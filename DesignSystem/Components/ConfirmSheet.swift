//
//  ConfirmSheet.swift
//  EnglishHelper — DesignSystem
//
//  The app's way to ask before an action — a sheet sized to its content, not a pop-up dialog: an icon,
//  a title, what's going to happen, optional details (a list of phrases, say), then the choices as
//  full-width buttons (the first one leads) and Cancel. Choosing anything closes it first.
//
//      .sheet(isPresented: $asking) {
//          ConfirmSheet(icon: "trash", title: "Clear the cache?", message: "…",
//                       actions: [ConfirmAction("Clear", role: .destructive) { clear() }])
//      }
//

import SwiftUI

public struct ConfirmAction: Identifiable {
    public enum Role { case primary, secondary, destructive }

    public let id: String
    let title: String
    let icon: String?
    let role: Role
    let perform: () -> Void

    public init(_ title: String, icon: String? = nil, role: Role = .primary, accessibilityID: String? = nil,
                perform: @escaping () -> Void) {
        self.id = accessibilityID ?? title
        self.title = title
        self.icon = icon
        self.role = role
        self.perform = perform
    }
}

public struct ConfirmSheet<Details: View>: View {
    private let icon: String
    private let title: String
    private let message: String?
    private let actions: [ConfirmAction]
    private let cancelTitle: String
    private let details: Details
    @State private var height: CGFloat = 320
    @Environment(\.dismiss) private var dismiss

    public init(icon: String, title: String, message: String? = nil, actions: [ConfirmAction],
                cancelTitle: String = DSLoc.t("Отмена", "Cancel"), @ViewBuilder details: () -> Details) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions
        self.cancelTitle = cancelTitle
        self.details = details()
    }

    public var body: some View {
        VStack(spacing: Tokens.Space.s16) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Tokens.Content.primary)
                .frame(width: 56, height: 56)
                .background(Tokens.Fill.subtle, in: Circle())
                .accessibilityHidden(true)
            VStack(spacing: Tokens.Space.s8) {
                Text(title)
                    .textStyle(Tokens.Text.title3)
                    .foregroundStyle(Tokens.Content.primary)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .textStyle(Tokens.Text.subhead)
                        .foregroundStyle(Tokens.Content.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            details
            VStack(spacing: Tokens.Space.s8) {
                ForEach(actions) { action in
                    EHButton(action.title, icon: action.icon, kind: kind(action.role), fillWidth: true,
                             accessibilityID: action.id) {
                        dismiss()
                        action.perform()
                    }
                }
                EHButton(cancelTitle, kind: .ghost, fillWidth: true, accessibilityID: "confirm.cancel") { dismiss() }
            }
            .padding(.top, Tokens.Space.s4)
        }
        .padding(.horizontal, Tokens.Space.s20)
        .padding(.top, Tokens.Space.s24)
        .padding(.bottom, Tokens.Space.s8)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
    }

    private func kind(_ role: ConfirmAction.Role) -> EHButton.Kind {
        switch role {
        case .primary: .primary
        case .secondary: .tonal
        case .destructive: .destructive
        }
    }
}

public extension ConfirmSheet where Details == EmptyView {
    init(icon: String, title: String, message: String? = nil, actions: [ConfirmAction],
         cancelTitle: String = DSLoc.t("Отмена", "Cancel")) {
        self.init(icon: icon, title: title, message: message, actions: actions, cancelTitle: cancelTitle) { EmptyView() }
    }
}
