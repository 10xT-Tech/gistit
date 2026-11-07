//
//  GlassTabBar.swift
//  EnglishHelper — DesignSystem
//
//  The app's floating Liquid Glass tab bar: the SYSTEM UITabBar, used standalone. Not inside a
//  TabView / UITabBarController — the main screens live side by side so a swipe can slide one over
//  its live neighbour, and TabView only renders the selected tab. A standalone UITabBar still draws
//  the iOS 26 bar and keeps all of its behaviour: glass capsule, the selection lens you can press
//  and drag across the items, Reduce Transparency, Large Content Viewer, tab-bar accessibility.
//
//  Placement: like a UITabBarController's bar, its frame runs down to the screen edge (UIKit's height
//  includes the bottom safe area) — `ignoresSafeArea` lets it, so the capsule sits where the system
//  puts it and the screens' safe area ends at the bar's top.
//

import SwiftUI
import UIKit

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

    public init(items: [GlassTabBarItem], selection: Binding<String>) {
        self.items = items
        self._selection = selection
    }

    public var body: some View {
        SystemTabBar(items: items, selection: $selection)
            .ignoresSafeArea(.container, edges: .bottom)
    }
}

private struct SystemTabBar: UIViewRepresentable {
    let items: [GlassTabBarItem]
    @Binding var selection: String

    func makeUIView(context: Context) -> UITabBar {
        let bar = UITabBar()
        bar.delegate = context.coordinator
        // Monochrome design: the selected item is told apart by the system's selection pill, not color.
        bar.tintColor = UIColor(Tokens.Content.primary)
        return bar
    }

    func updateUIView(_ bar: UITabBar, context: Context) {
        context.coordinator.items = items
        context.coordinator.select = { selection = $0 }
        // Titles follow the in-app language, so they can change while the bar is alive.
        if bar.items?.map(\.title) != items.map(\.title) {
            bar.items = items.enumerated().map { index, item in
                let tabItem = UITabBarItem(title: item.title, image: Self.image(item.systemImage), tag: index)
                tabItem.accessibilityIdentifier = "tab.\(item.id)"
                return tabItem
            }
        }
        if let index = items.firstIndex(where: { $0.id == selection }), bar.selectedItem?.tag != index {
            bar.selectedItem = bar.items?[index]
        }
    }

    /// UIKit's height already includes the bottom safe area; `ignoresSafeArea` lays it over that
    /// area, so only the part above it is reserved for the screens.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITabBar, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        return CGSize(width: width,
                      height: uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The system tab bar fills its icons; UIKit doesn't do it for us, so prefer the `.fill` variant.
    private static func image(_ name: String) -> UIImage? {
        UIImage(systemName: name.hasSuffix(".fill") ? name : name + ".fill") ?? UIImage(systemName: name)
    }

    final class Coordinator: NSObject, UITabBarDelegate {
        var items: [GlassTabBarItem] = []
        var select: (String) -> Void = { _ in }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            guard items.indices.contains(item.tag) else { return }
            select(items[item.tag].id)
        }
    }
}
