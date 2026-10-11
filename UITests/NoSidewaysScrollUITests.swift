//
//  NoSidewaysScrollUITests.swift
//  EnglishHelper — UITests
//
//  Every screen scrolls up/down only: a sideways swipe must not move the page (VerticalScrollView).
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
            app.tabBars.buttons[tab].tap()
            assertStaysPut(app, screen: tab)
        }
        // Settings sheet.
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        assertStaysPut(app, screen: "Settings")
    }

    /// Swipes the page left and right and checks its widest visible text didn't move horizontally.
    private func assertStaysPut(_ app: XCUIApplication, screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "\(screen): no scroll view", file: file, line: line)
        let probe = scroll.staticTexts.allElementsBoundByIndex.first { $0.isHittable && $0.frame.width > 40 }
            ?? scroll.buttons.allElementsBoundByIndex.first { $0.isHittable }
        guard let probe else { return XCTFail("\(screen): nothing to measure", file: file, line: line) }
        let before = probe.frame.minX
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        let duringLeft = probe.frame.minX
        start.press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertEqual(duringLeft, before, accuracy: 1, "\(screen) moved sideways", file: file, line: line)
        XCTAssertEqual(probe.frame.minX, before, accuracy: 1, "\(screen) moved sideways", file: file, line: line)
    }
}
