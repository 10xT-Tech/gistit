//
//  GlassTabBar.swift
//  EnglishHelper — DesignSystem
//
//  The app's floating Liquid Glass tab bar. Replaces the system TabView bar so the main screens can
//  live side by side (a swipe slides one screen over its live neighbour — TabView only renders the
//  selected tab). Looks and behaves like the iOS 26 bar: glass capsule, icon over a short label, a
//  tonal pill under the selected item that glides between items; solid under Reduce Transparency;
//  exposed to accessibility as a tab bar with selectable tabs and Large Content Viewer support.
//

import SwiftUI

public struct GlassTabBarItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String

    public init(id: String, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

public struct GlassTabBar: View {
    private let items: [GlassTabBarItem]
    @Binding private var selection: String
    @Namespace private var pill
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(items: [GlassTabBarItem], selection: Binding<String>) {
        self.items = items
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                tabButton(item)
            }
        }
        .padding(4)
        .background { background }
        .animation(.snappy(duration: 0.28), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }

    private func tabButton(_ item: GlassTabBarItem) -> some View {
        let selected = item.id == selection
        return Button {
            selection = item.id
        } label: {
            VStack(spacing: 1) {
                Image(systemName: item.systemImage)
                    .symbolVariant(.fill)   // the system tab bar fills its icons too
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 26)
                Text(item.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(Tokens.Content.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if selected {
                    Capsule()
                        .fill(Tokens.Fill.default)
                        .matchedGeometryEffect(id: "selection", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("tab.\(item.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label(item.title, systemImage: item.systemImage)
        }
    }

    @ViewBuilder private var background: some View {
        if reduceTransparency {
            Capsule()
                .fill(Tokens.Surface.primary)
                .overlay(Capsule().strokeBorder(Tokens.Glass.border, lineWidth: Tokens.Hairline.width))
        } else {
            Color.clear.glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}
