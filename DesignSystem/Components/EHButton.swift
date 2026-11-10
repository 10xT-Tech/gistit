//
//  EHButton.swift
//  EnglishHelper — DesignSystem
//
//  Pill button, five kinds (the design kit's primary / glass / tonal / ghost, plus destructive — a red
//  fill for an action that deletes, a functional signal).
//

import SwiftUI

public struct EHButton: View {
    public enum Kind: Sendable { case primary, glass, tonal, ghost, destructive }

    private let title: String
    private let icon: String?
    private let kind: Kind
    private let fillWidth: Bool
    private let accessibilityID: String?
    private let action: () -> Void
    /// `.buttonStyle(.plain)` doesn't dim on `.disabled()`, so read the environment and dim ourselves —
    /// otherwise a disabled primary button looks fully active (a silent dead button).
    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: String, icon: String? = nil, kind: Kind = .primary,
                fillWidth: Bool = false, accessibilityID: String? = nil,
                action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.fillWidth = fillWidth
        self.accessibilityID = accessibilityID
        self.action = action
    }

    @Environment(\.swipeSafeButtons) private var swipeSafe

    public var body: some View {
        if swipeSafe {
            button.buttonStyle(SwipeSafeButtonStyle())
        } else {
            button.buttonStyle(.plain)
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.s8) {
                if let icon { Image(systemName: icon) }
                Text(title)
                    .multilineTextAlignment(.center)   // 2-line labels center like MicButton's caption
            }
            .font(Tokens.Text.headline.font)   // scales with Dynamic Type (was a fixed 16pt)
            .tracking(-0.2)
            .foregroundStyle(foreground)
            .frame(minHeight: 50)              // minHeight so the pill grows with larger text
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .padding(.horizontal, Tokens.Space.s20)
            .background(background)
            .clipShape(Capsule())
            .overlay {
                if kind == .glass {
                    Capsule().strokeBorder(Tokens.Glass.border, lineWidth: Tokens.Hairline.width)
                }
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityIdentifier(accessibilityID ?? "")
    }

    private var foreground: Color {
        switch kind {
        case .primary: Tokens.Content.onInvert
        case .glass, .tonal, .ghost: Tokens.Content.primary
        case .destructive: Tokens.Content.onSignal
        }
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .primary: Tokens.Surface.invert
        case .glass:   Color.clear.glassPanelCapsule()
        case .tonal:   Tokens.Fill.default
        case .ghost:   Color.clear
        case .destructive: Tokens.Signal.error
        }
    }
}

private extension View {
    /// Capsule glass fill honoring Reduce Transparency. Mirrors `glassPanel`'s solid fallback but for a
    /// Capsule shape (glassPanel is rounded-rect only), so the two are intentionally parallel.
    func glassPanelCapsule() -> some View { modifier(CapsuleGlass()) }
}

private struct CapsuleGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency { Capsule().fill(Tokens.Surface.primary) }
            else { Capsule().fill(Tokens.Material.glass) }
        }
    }
}
