//
//  SwipeSafeButtonStyle.swift
//  EnglishHelper — DesignSystem
//
//  A button that fires on a TAP only. A plain SwiftUI button inside a vertical scroll view also fires
//  when a sideways swipe starts and ends on it — on a screen with no neighbouring tab to swipe to
//  (Study is the first), sweeping across a full-width row opened it. Here the press is a tap gesture,
//  which fails as soon as the finger travels. Dims while pressed, like `.plain`.
//

import SwiftUI

public struct SwipeSafeButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Pressable(configuration: configuration)
    }

    private struct Pressable: View {
        let configuration: Configuration
        @GestureState private var pressed = false

        var body: some View {
            configuration.label
                .opacity(pressed ? 0.55 : 1)
                .contentShape(Rectangle())
                .gesture(TapGesture().onEnded { configuration.trigger() })
                // Press feedback only: never completes; moving more than a few points ends it.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 60, maximumDistance: 10)
                        .updating($pressed) { value, state, _ in state = value }
                )
        }
    }
}

public extension EnvironmentValues {
    /// Screens whose content can be swiped sideways set this, so `EHButton`s inside fire on taps only.
    @Entry var swipeSafeButtons = false
}
