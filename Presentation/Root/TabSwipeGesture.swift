//
//  TabSwipeGesture.swift
//  EnglishHelper — Presentation
//
//  Swipe left / right anywhere on a main screen to move to the neighbouring tab: the screen follows
//  the finger and slides aside over its live neighbour (RootView keeps all screens alive). A UIKit pan
//  (via `UIGestureRecognizerRepresentable`) rather than a SwiftUI DragGesture, because it has to
//  coexist with gestures SwiftUI can't arbitrate: List swipe actions (Study: both edges; History:
//  swipe-left to delete), text selection/cursor drags, and vertical scrolling. It only BEGINS on a
//  clearly horizontal pan, recognises simultaneously with everything else, and acts on touch-up.
//

import SwiftUI
import UIKit

/// The pure part: tab order, neighbours and the "was that a tab swipe?" decision (unit-tested).
public enum TabSwipe {
    /// Finger moved right → previous tab (to the left); finger moved left → next tab.
    public enum Direction: Equatable, Sendable { case previous, next }

    /// What a pan that starts on a List row may do on this tab — rows can carry swipe actions.
    public enum RowPolicy: Equatable, Sendable {
        case any                // no row swipe actions
        case previousOnly       // trailing actions only (swipe-left = delete): swipe-right still switches
        case none               // actions on both edges: rows never switch tabs
    }

    /// Tab order, left to right — MUST match the `TabView` in RootView.
    public static let order = ["library", "camera", "out", "in", "history"]

    public static func neighbour(of tab: String, _ direction: Direction) -> String? {
        guard let i = order.firstIndex(of: tab) else { return nil }
        let j = direction == .next ? i + 1 : i - 1
        return order.indices.contains(j) ? order[j] : nil
    }

    public static func rowPolicy(for tab: String) -> RowPolicy {
        switch tab {
        case "library": .none
        case "history": .previousOnly
        default: .any
        }
    }

    /// Which way a pan that has just started is heading, or nil when it isn't clearly horizontal
    /// (vertical scrolls and diagonal drags stay with whoever else wants them).
    public static func startDirection(velocity: CGPoint) -> Direction? {
        guard abs(velocity.x) > 1.5 * abs(velocity.y) else { return nil }
        return velocity.x < 0 ? .next : .previous
    }

    /// Whether a finished pan commits the switch: far enough, or a quick flick in the same direction.
    public static func commits(_ direction: Direction, translation: CGPoint, velocity: CGPoint) -> Bool {
        let dx = direction == .next ? -translation.x : translation.x
        let vx = direction == .next ? -velocity.x : velocity.x
        guard dx > abs(translation.y) else { return false }   // ended up mostly vertical
        return dx >= 70 || (dx >= 30 && vx >= 500)
    }
}

/// Shared paging state: which tab is following the finger, and by how much. Every main screen is
/// alive in the container (RootView), so the neighbour shown underneath is the real, current screen.
@MainActor @Observable
final class TabPager {
    /// The tab whose content is following the finger, and by how much (points, + = right).
    private(set) var draggingTab: String?
    private(set) var offset: CGFloat = 0

    /// The neighbour uncovered under `tab` while it slides, if any.
    func revealed(under tab: String) -> String? {
        guard draggingTab == tab, offset != 0 else { return nil }
        return TabSwipe.neighbour(of: tab, offset < 0 ? .next : .previous)
    }

    func drag(_ tab: String, to offset: CGFloat) {
        draggingTab = tab
        self.offset = offset
    }

    /// Animate the screen off (commit) or back (cancel); `done` runs once it has landed.
    func settle(to offset: CGFloat, done: @escaping () -> Void) {
        withAnimation(.snappy(duration: 0.26)) {
            self.offset = offset
        } completion: { [weak self] in
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                done()
                self?.offset = 0
                self?.draggingTab = nil
            }
        }
    }
}

/// The gesture itself: drives `pager` while the finger moves, commits or springs back on release.
struct TabSwipeGesture: UIGestureRecognizerRepresentable {
    let tab: String
    let pager: TabPager
    let onSwipe: (String) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false   // taps / scrolls underneath keep working
        context.coordinator.tab = tab
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.tab = tab
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard let direction = context.coordinator.direction,
              let target = TabSwipe.neighbour(of: tab, direction) else { return }
        let view = recognizer.view
        let width = view?.bounds.width ?? 400
        let dx = recognizer.translation(in: view).x
        // Follow the finger only towards the neighbour (a reverse drag just pins the screen back).
        let following = direction == .next ? min(0, dx) : max(0, dx)
        let animated = !UIAccessibility.isReduceMotionEnabled

        switch recognizer.state {
        case .began, .changed:
            if animated { pager.drag(tab, to: following) }
        case .ended:
            let commit = TabSwipe.commits(direction, translation: recognizer.translation(in: view),
                                          velocity: recognizer.velocity(in: view))
            guard animated else { if commit { onSwipe(target) }; return }
            if commit {
                pager.settle(to: direction == .next ? -width : width) { onSwipe(target) }
            } else {
                pager.settle(to: 0) {}
            }
        case .cancelled, .failed:
            if animated { pager.settle(to: 0) {} }
        default:
            break
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var tab = ""
        /// Set when the pan begins; read until touch-up.
        var direction: TabSwipe.Direction?
        private var touchStartedOnRow = false

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            touchStartedOnRow = false
            while let v = view {
                // Text editing owns horizontal drags (cursor, selection).
                if v is UITextView || v is UITextField { return false }
                if v is UICollectionViewCell || v is UITableViewCell { touchStartedOnRow = true }
                view = v.superview
            }
            return !(touchStartedOnRow && TabSwipe.rowPolicy(for: tab) == .none)
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            direction = nil
            guard let pan = g as? UIPanGestureRecognizer,
                  let heading = TabSwipe.startDirection(velocity: pan.velocity(in: pan.view)),
                  TabSwipe.neighbour(of: tab, heading) != nil else { return false }
            if touchStartedOnRow, TabSwipe.rowPolicy(for: tab) == .previousOnly, heading == .next {
                return false   // that's the row's swipe-to-delete
            }
            direction = heading
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
