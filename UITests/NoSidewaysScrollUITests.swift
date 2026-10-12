//
//  NoSidewaysScrollUITests.swift
//  EnglishHelper — UITests
//
//  Every screen scrolls up/down only: a sideways drag must not move the page (VerticalScrollView).
//  The drags stay SHORT (~24 pt, slow) — below TabSwipe's commit threshold, so they probe the page
//  without switching tabs (a long swipe now moves to the neighbouring tab by design, TabSwipeUITests);
//  a page wider than the screen would still visibly follow them.
//

import XCTest

final class NoSidewaysScrollUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    func testNoScreenDriftsSideways() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
            "-sayItMode", "howToSay", "-getItMode", "translate", "-seeItMode", "translate",
        ]
        app.launch()

        for tab in ["Say it", "Get it", "See it"] {
            app.tab(tab).tap()
            assertStaysPut(app, screen: tab)
        }
        // Settings sheet.
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        assertStaysPut(app, screen: "Settings")
    }

    /// Drags the page a little left and right and checks its widest visible text didn't move horizontally.
    private func assertStaysPut(_ app: XCUIApplication, screen: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 5), "\(screen): no scroll view", file: file, line: line)
        // The one on top: under a sheet (Settings) the screen behind keeps its scroll view too.
        guard let scroll = app.scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            return XCTFail("\(screen): no hittable scroll view", file: file, line: line)
        }
        let probe = scroll.staticTexts.allElementsBoundByIndex.first { $0.isHittable && $0.frame.width > 40 }
            ?? scroll.buttons.allElementsBoundByIndex.first { $0.isHittable }
        guard let probe else { return XCTFail("\(screen): nothing to measure", file: file, line: line) }
        let before = probe.frame.minX
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        let duringLeft = probe.frame.minX
        start.press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.navigationBars[screen].exists, "\(screen): a short drag switched tabs", file: file, line: line)
        XCTAssertEqual(duringLeft, before, accuracy: 1, "\(screen) moved sideways", file: file, line: line)
        XCTAssertEqual(probe.frame.minX, before, accuracy: 1, "\(screen) moved sideways", file: file, line: line)
    }
}
