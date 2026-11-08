//
//  FlashcardsUITests.swift
//  EnglishHelper — UITests
//
//  The Study dashboard and flashcard practice end to end on the stub data (two saved expressions, none
//  in flashcards): dashboard → Saved for later → swipe a phrase right into flashcards → back → Start →
//  Show answer → Good (a 10-minute learning step, so it comes back) → Show answer → Good (graduates)
//  → done → the dashboard counts the two answers.
//

import XCTest

final class FlashcardsUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    func testMoveToFlashcardsAndPractice() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
        ]
        app.launch()
        app.tab("Study").tap()

        // Nothing in flashcards yet: the dashboard points to Saved for later.
        XCTAssertTrue(app.buttons["flashcards.openSaved"].waitForExistence(timeout: 5))
        attach(app, "dashboard-empty")
        app.buttons["study.saved"].tap()

        // Swipe right: the phrase moves into flashcards and leaves the list.
        XCTAssertTrue(app.navigationBars["Saved for later"].waitForExistence(timeout: 3))
        let row = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'I appreciate it'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        attach(app, "saved")
        row.swipeRight()
        let learn = app.buttons["Learn"]
        if learn.waitForExistence(timeout: 2) { learn.tap() }   // a short swipe only reveals the action
        XCTAssertTrue(row.waitForNonExistence(timeout: 3), "the phrase stayed in Saved for later")
        app.navigationBars["Saved for later"].buttons.element(boundBy: 0).tap()

        let start = app.buttons["flashcards.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        attach(app, "dashboard")
        start.tap()

        let reveal = app.buttons["flashcards.reveal"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["I appreciate it"].exists, "recognition shows the studied phrase")
        attach(app, "front")
        reveal.tap()

        let good = app.buttons["flashcards.rate.good"]
        XCTAssertTrue(good.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Я ценю это"].exists, "the answer shows the meaning")
        attach(app, "back")
        good.tap()

        // The learning step (10 min) is inside the session's learn-ahead window: the card is back.
        XCTAssertTrue(reveal.waitForExistence(timeout: 3))
        reveal.tap()
        good.tap()

        XCTAssertTrue(app.staticTexts["All done for today"].waitForExistence(timeout: 3))
        app.buttons["Close"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["All done for today — come back tomorrow."].waitForExistence(timeout: 3))
        XCTAssertFalse(start.isEnabled)
        attach(app, "dashboard-after")
    }

    /// Flashcards are Pro: on the free plan Start carries a lock and opens the paywall.
    func testFreePlanGetsThePaywall() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES", "-uiTestFreePlan",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
        ]
        app.launch()
        app.tab("Study").tap()
        let start = app.buttons["flashcards.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.staticTexts["Gist It Pro"].firstMatch.waitForExistence(timeout: 5), "the paywall didn't open")
        XCTAssertFalse(app.buttons["flashcards.reveal"].exists)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
