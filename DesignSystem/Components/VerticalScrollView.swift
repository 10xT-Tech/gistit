//
//  VerticalScrollView.swift
//  EnglishHelper — DesignSystem
//
//  The app's only kind of page scrolling: up/down, never sideways. The content is pinned to the
//  scroll view's width, so nothing inside (a wide photo, a long unbreakable word, a status line)
//  can make the page wider than the screen and let it drift left/right; horizontal bounce is off.
//  Scroll modifiers (`scrollPosition`, `onScrollGeometryChange`, `scrollDismissesKeyboard`, …)
//  applied to it reach the inner ScrollView as usual.
//

import SwiftUI

public struct VerticalScrollView<Content: View>: View {
    private let showsIndicators: Bool
    private let content: Content

    public init(showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: showsIndicators) {
            content.containerRelativeFrame(.horizontal)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}
