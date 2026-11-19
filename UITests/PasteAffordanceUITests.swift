//
//  PasteAffordanceUITests.swift
//  EnglishHelper — UITests
//
//  The Get-it action slot against the REAL system pasteboard, changed from the test-runner process
//  (a different process, like Universal Clipboard or a password manager) while the app is in the
//  foreground — the case iOS never announces with UIPasteboard.changedNotification. Rules:
//  empty clipboard + empty field → disabled Explain/Translate; text on the clipboard → Paste;
//  text in the field → Explain/Translate. And when iOS can't draw its paste control in this process
//  (`-uiTestPasteControlUnavailable`; in real life its drawing service died under the app and the
//  slot was an empty, dead rectangle until relaunch) the slot is the app's own Paste button.
//

import XCTest

final class PasteAffordanceUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launchGetIt(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += extra + [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
            "-toneOfVoice", "casual", "-sayItMode", "howToSay", "-getItMode", "explain", "-seeItMode", "explain",
        ]
        app.launch()
        app.tab("Get it").tap()
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

    /// Clipboard content the system control refuses (rich text with no plain-text form) must not arm
    /// the slot: it used to show a greyed-out Paste and no Explain.
    func testRichTextWithoutPlainTextKeepsTheModeButton() {
        UIPasteboard.general.setItems([["public.rtf": Data("{\\rtf1\\ansi hello}".utf8)]])
        let app = launchGetIt()
        let action = app.buttons["getit.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1.5)   // past the first clipboard looks
        XCTAssertEqual(action.label, "Explain")
        XCTAssertFalse(action.isEnabled)
    }

    /// iOS can't draw its paste control: the app's own Paste button stands in, reads the clipboard
    /// (iOS asks to allow it) and fills the field — the slot goes back to Explain, nothing is sent.
    func testTheAppsOwnPasteButtonStandsInForTheSystemControl() {
        UIPasteboard.general.string = "break a leg"
        let app = launchGetIt(["-uiTestPasteControlUnavailable"])
        let action = app.buttons["getit.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        XCTAssertEqual(action.label, "Paste")
        XCTAssertTrue(drawsSomething(action), "the Paste slot is empty")
        action.tap()

        if allowPaste(app) {
            let field = app.descendants(matching: .any).matching(identifier: "getit.input").firstMatch
            let filled = expectation(for: NSPredicate(format: "value == %@", "break a leg"), evaluatedWith: field)
            wait(for: [filled], timeout: 5)
            XCTAssertEqual(action.label, "Explain")
            XCTAssertTrue(action.isEnabled)
        } else {
            expectRefusedPasteLeavesTheModeButton(action)
        }
    }

    /// The same on Say it — the two screens share the slot.
    func testTheAppsOwnPasteButtonOnSayIt() {
        UIPasteboard.general.string = "how do I thank them"
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestPasteControlUnavailable",
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
            "-toneOfVoice", "casual", "-sayItMode", "howToSay", "-getItMode", "explain", "-seeItMode", "explain",
        ]
        app.launch()
        app.tab("Say it").tap()
        let action = app.buttons["sayit.action"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertEqual(action.label, "Paste")
        XCTAssertTrue(drawsSomething(action), "the Paste slot is empty")
        action.tap()

        if allowPaste(app) {
            let changed = expectation(for: NSPredicate(format: "label != %@ AND enabled == YES", "Paste"), evaluatedWith: action)
            wait(for: [changed], timeout: 5)
        } else {
            expectRefusedPasteLeavesTheModeButton(action)
        }
    }

    /// iOS asks before an app reads what ANOTHER app copied (here: the test runner): "“Gist It” would
    /// like to paste from …" → Allow Paste. False when no question came — the iOS 27.0 Simulator can't
    /// show it at all (its pasteboard service isn't entitled to post the alert, the read is refused
    /// at once); the iOS 26.4 Simulator and devices do ask.
    private func allowPaste(_ app: XCUIApplication) -> Bool {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        guard allow.waitForExistence(timeout: 3) else { return false }
        allow.tap()
        return true
    }

    /// The read was refused (the user said no, or the Simulator can't ask): nothing pasted, and the
    /// slot is the mode button again — not a Paste that asks on every tap.
    private func expectRefusedPasteLeavesTheModeButton(_ action: XCUIElement) {
        let back = expectation(for: NSPredicate(format: "label != %@ AND enabled == NO", "Paste"), evaluatedWith: action)
        wait(for: [back], timeout: 5)
        Thread.sleep(forTimeInterval: 2.2)   // past the next looks at the clipboard
        XCTAssertNotEqual(action.label, "Paste")
        XCTAssertFalse(action.isEnabled)
    }

    /// Whether anything is painted in the element's frame — accessibility says "Paste, enabled" for
    /// an empty system control just the same, so the pixels are the only witness.
    private func drawsSomething(_ element: XCUIElement) -> Bool {
        let shot = XCUIScreen.main.screenshot().image
        let scale = shot.scale, frame = element.frame
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        guard let crop = shot.cgImage?.cropping(to: rect) else { return false }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        var darkest = 255, lightest = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let value = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
            darkest = min(darkest, value); lightest = max(lightest, value)
        }
        return lightest - darkest > 40
    }
}
