//
//  PasteAffordanceUITests.swift
//  EnglishHelper — UITests
//
//  The Get-it action slot against the REAL system pasteboard, changed from the test-runner process
//  (a different process, like Universal Clipboard or a password manager) while the app is in the
//  foreground — the case iOS never announces with UIPasteboard.changedNotification. Rules:
//  empty clipboard + empty field → disabled Explain/Translate; text on the clipboard → Paste;
//  text in the field → Explain/Translate.
//

import XCTest

final class PasteAffordanceUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchGetIt() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
            "-toneOfVoice", "casual", "-sayItMode", "howToSay", "-getItMode", "explain", "-seeItMode", "explain",
        ]
        app.launch()
        app.tabBars.buttons["Get it"].tap()
        XCTAssertTrue(app.navigationBars["Get it"].waitForExistence(timeout: 5))
        return app
    }

    /// Text cleared from the clipboard by another process while on screen: the slot must go back to
    /// the (disabled) mode button — not keep a greyed-out Paste with no Explain anywhere.
    func testExternalClipboardClearRestoresDisabledModeButton() {
        UIPasteboard.general.string = "hello"
        let app = launchGetIt()
        let action = app.buttons["getit.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        XCTAssertEqual(action.label, "Paste")

        UIPasteboard.general.items = []
        let predicate = NSPredicate(format: "label == %@ AND enabled == NO", "Explain")
        let back = expectation(for: predicate, evaluatedWith: action)
        wait(for: [back], timeout: 5)
    }

    /// Text copied by another process while on screen: the slot must offer Paste.
    func testExternalCopyOffersPaste() {
        UIPasteboard.general.items = []
        let app = launchGetIt()
        let action = app.buttons["getit.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        XCTAssertEqual(action.label, "Explain")
        XCTAssertFalse(action.isEnabled)

        UIPasteboard.general.string = "arrived later"
        let predicate = NSPredicate(format: "label == %@ AND enabled == YES", "Paste")
        let paste = expectation(for: predicate, evaluatedWith: action)
        wait(for: [paste], timeout: 5)
    }
}
