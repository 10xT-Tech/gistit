//
//  TabSwipeUITests.swift
//  EnglishHelper — UITests
//
//  Swiping left / right on a main screen moves to the neighbouring tab (TabSwipeGesture) and stops
//  at both ends — without stealing the List rows' own swipe actions: Study rows (both edges) and
//  History's swipe-left-to-delete must still reveal their buttons instead of switching tabs.
//

import XCTest

final class TabSwipeUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
            "-sayItMode", "howToSay", "-getItMode", "translate", "-seeItMode", "translate",
        ]
        app.launch()
        return app
    }

    private func assertOn(_ app: XCUIApplication, _ title: String, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3), "expected the \(title) tab", line: line)
    }

    /// Swipe across the middle of the screen (clear of the tab bar and the input fields).
    private func swipe(_ app: XCUIApplication, left: Bool) {
        let w = app.windows.firstMatch
        let from = w.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: 0.62))
        let to = w.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.85, dy: 0.62))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
    }

    func testSwipesWalkTheTabsAndStopAtTheEnds() {
        let app = launch()
        assertOn(app, "Say it")
        swipe(app, left: true);  assertOn(app, "Get it")
        swipe(app, left: true);  assertOn(app, "History")
        swipe(app, left: true);  assertOn(app, "History")   // last tab: nowhere to go
        swipe(app, left: false); assertOn(app, "Get it")
        swipe(app, left: false); assertOn(app, "Say it")
        swipe(app, left: false); assertOn(app, "See it")
        swipe(app, left: false); assertOn(app, "Study")
        swipe(app, left: false); assertOn(app, "Study")     // first tab: nowhere to go
    }

    /// Only the selected screen is mounted: VoiceOver (and XCUI) must never reach a screen that
    /// isn't on display — neither at launch nor after switching.
    func testOnlyTheSelectedScreenIsInTheAccessibilityTree() {
        let app = launch()
        assertOn(app, "Say it")
        XCTAssertEqual(app.navigationBars.count, 1, "hidden screens leaked into accessibility")
        app.tab("History").tap()
        assertOn(app, "History")
        XCTAssertEqual(app.navigationBars.count, 1, "hidden screens leaked into accessibility")
        XCTAssertTrue(app.tab("History").isSelected)
    }

    func testRowSwipeActionsStillWinOverTabSwitching() {
        let app = launch()
        // A Say-it result → one History row; saving a card → one Study row.
        let input = app.textViews["sayit.input"].exists ? app.textViews["sayit.input"] : app.textFields["sayit.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("help me")
        app.buttons["sayit.action"].tap()
        let save = app.buttons["Save to study list"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()

        // History: swipe-left on the row is delete, not "next tab".
        app.tab("History").tap()
        let historyRow = app.cells.firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))
        historyRow.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3), "History delete action did not appear")
        assertOn(app, "History")

        // Study: rows have actions on both edges — neither direction switches tabs.
        app.tab("Study").tap()
        let studyRow = app.cells.firstMatch
        XCTAssertTrue(studyRow.waitForExistence(timeout: 5))
        studyRow.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3), "Study delete action did not appear")
        assertOn(app, "Study")
    }
}
