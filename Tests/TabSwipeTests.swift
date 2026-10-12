//
//  TabSwipeTests.swift
//  EnglishHelper — Tests
//
//  The swipe-between-tabs decision table: neighbours at both ends, what counts as a horizontal swipe,
//  when a finished pan commits, and which tabs let a swipe start on a List row (rows carry swipe
//  actions — Study on both edges, History swipe-left to delete).
//

import Testing
import CoreGraphics
import Presentation

@Suite struct TabSwipeTests {

    @Test func neighboursFollowTheTabBarAndStopAtTheEnds() {
        #expect(TabSwipe.order == ["library", "camera", "out", "in", "history"])
        #expect(TabSwipe.neighbour(of: "out", .next) == "in")
        #expect(TabSwipe.neighbour(of: "out", .previous) == "camera")
        #expect(TabSwipe.neighbour(of: "library", .previous) == nil)   // first tab
        #expect(TabSwipe.neighbour(of: "history", .next) == nil)       // last tab
        #expect(TabSwipe.neighbour(of: "unknown", .next) == nil)
    }

    @Test func onlyClearlyHorizontalPansStart() {
        #expect(TabSwipe.startDirection(velocity: CGPoint(x: -800, y: 100)) == .next)      // finger left
        #expect(TabSwipe.startDirection(velocity: CGPoint(x: 800, y: -100)) == .previous)  // finger right
        #expect(TabSwipe.startDirection(velocity: CGPoint(x: 300, y: 900)) == nil)         // a scroll
        #expect(TabSwipe.startDirection(velocity: CGPoint(x: 500, y: 400)) == nil)         // diagonal
    }

    @Test func commitsOnDistanceOrQuickFlick() {
        #expect(TabSwipe.commits(.next, translation: CGPoint(x: -80, y: 10), velocity: .zero))
        #expect(TabSwipe.commits(.previous, translation: CGPoint(x: 40, y: 5), velocity: CGPoint(x: 900, y: 0)))
        #expect(!TabSwipe.commits(.next, translation: CGPoint(x: -40, y: 5), velocity: CGPoint(x: -100, y: 0)))
        #expect(!TabSwipe.commits(.next, translation: CGPoint(x: 80, y: 0), velocity: .zero))   // went back
        #expect(!TabSwipe.commits(.next, translation: CGPoint(x: -80, y: 120), velocity: .zero)) // turned vertical
    }

    @Test func rowPoliciesMatchEachScreensSwipeActions() {
        #expect(TabSwipe.rowPolicy(for: "library") == .none)          // leading + trailing actions
        #expect(TabSwipe.rowPolicy(for: "history") == .previousOnly)  // trailing delete only
        #expect(TabSwipe.rowPolicy(for: "out") == .any)
    }
}
