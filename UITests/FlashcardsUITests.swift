//
//  FlashcardsUITests.swift
//  EnglishHelper — UITests
//
//  Flashcard practice end to end on the stub study list (one active expression → one new card):
//  Study → Start → Show answer → Good (a 10-minute learning step, so it comes back) → Show answer →
//  Good (graduates) → done → back on Study with nothing left for today.
//

import XCTest

final class FlashcardsUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    func testPracticeSessionFromStudy() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
        ]
        app.launch()
        app.tab("Study").tap()

        let start = app.buttons["flashcards.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["To review: 0 · new: 1"].exists)
        attach(app, "study")
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

        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(app.staticTexts["All done for today"].waitForExistence(timeout: 3))
        attach(app, "done")
        close.tap()

        XCTAssertTrue(app.staticTexts["All done for today — come back tomorrow."].waitForExistence(timeout: 3))
        XCTAssertFalse(start.isEnabled)
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
