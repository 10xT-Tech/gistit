//
//  AppStoreScreenshotUITests.swift
//  EnglishHelper — UITests
//
//  The Study screens for the App Store, on the believable French deck (`-screenshotDeck`): the
//  dashboard, a flashcard (question and answer), In flashcards and Caught. Kept as screenshot
//  attachments — run on the 6.9" and 6.3" simulators with the status bar overridden (09:41, full
//  battery), export with xcresulttool. Not part of the regular suite's assertions beyond reaching
//  each screen.
//

import XCTest

final class AppStoreScreenshotUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    func testStudyScreens() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-screenshotDeck", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "french", "-targetLanguage", "english",
            "-AppleLanguages", "(en-GB)", "-AppleLocale", "en_GB",
        ]
        app.launch()
        app.tab("Study").tap()
        let start = app.buttons["flashcards.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        sleep(2)
        shoot("07-study-dashboard")

        start.tap()
        let reveal = app.buttons["flashcards.reveal"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        sleep(1)
        shoot("08-flashcard-question")
        reveal.tap()
        sleep(1)
        shoot("09-flashcard-answer")
        app.buttons["flashcards.close"].firstMatch.tap()

        let studying = app.buttons["study.studying"]
        XCTAssertTrue(studying.waitForExistence(timeout: 5))
        studying.tap()
        sleep(2)
        shoot("10-in-flashcards")
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()

        let caught = app.buttons["study.caught"]
        XCTAssertTrue(caught.waitForExistence(timeout: 5))
        caught.tap()
        sleep(2)
        shoot("11-caught")
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
