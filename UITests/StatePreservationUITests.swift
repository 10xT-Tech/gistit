//
//  StatePreservationUITests.swift
//  EnglishHelper — UITests
//
//  Drives the REAL app (with deterministic stub adapters via `-uiTestStubs`) through the
//  tab-switching scenarios that must preserve each screen's state: generated results, the input
//  they were generated from, the selected mode (how-to-say/what-to-say, explain/translate), and
//  the tone. A spurious regeneration is caught two ways: the stub's 800 ms latency makes the
//  processing state visible, and History (in-memory repo) counts exactly one row per real request.
//

import XCTest

final class StatePreservationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launch with deterministic stubs, onboarding skipped, and a pinned EN interface so the
    /// label-based queries below are stable regardless of the simulator's locale.
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs",
            "-didCompleteOnboarding", "YES",
            "-didPrimeMic", "YES",
            "-interfaceLanguage", "en",
            "-studiedLanguage", "english",
            "-targetLanguage", "russian",
            "-toneOfVoice", "casual",
            // Modes/tone are persisted; the argument domain pins each launch's READS to the defaults,
            // and under -uiTestStubs the app WRITES them to an ephemeral suite wiped every launch
            // (Presentation/Support/Prefs.swift) — so test taps never leak into the next test or
            // into the real app's saved preferences on this simulator.
            "-sayItMode", "howToSay",
            "-getItMode", "explain",
            "-seeItMode", "explain",
        ]
        app.launch()
        return app
    }

    // Canned stub results (see MockLLMClient.cannedJSON) and screen copy.
    private let sayItCard = "Could you help me with this?"
    private let sayItProcessing = "Finding phrasings…"
    private let getItProcessing = "Translating…"

    // MARK: Helpers

    /// The GlassField's TextField: SwiftUI may expose a vertical-axis field as either element type.
    private func field(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let tf = app.textFields[id]
        return tf.exists ? tf : app.textViews[id]
    }

    private func fieldValue(_ element: XCUIElement) -> String {
        (element.value as? String) ?? ""
    }

    /// A SegmentedSelector segment, addressed by its stable identifier ("getit.mode.translate") —
    /// labels are ambiguous (the primary action button can share them) and localized.
    private func segment(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.buttons[id]
    }

    /// Type into a GlassField and run the request via the primary button, addressed by its
    /// accessibility IDENTIFIER (a label query is ambiguous: the mode segment can share the label,
    /// and index-based disambiguation re-resolves at tap time). A vertical-axis TextField inserts a
    /// newline on the return key, so `\n` would not submit. Tapping the button drops field focus
    /// in-app, so the keyboard only needs dismissing when it covers the button.
    private func typeAndSubmit(_ app: XCUIApplication, field: XCUIElement, text: String, buttonID: String) {
        field.tap()
        field.typeText(text)
        let action = app.buttons[buttonID]
        XCTAssertTrue(action.waitForExistence(timeout: 3), "action button \(buttonID) not found")
        if !action.isHittable { dismissKeyboard(app) }
        action.tap()
    }

    private func openTab(_ app: XCUIApplication, _ name: String) {
        dismissKeyboard(app)   // an open keyboard covers the tab bar
        app.tab(name).tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5), "tab \(name) did not open")
    }

    /// Dismiss the keyboard without submitting. `.scrollDismissesKeyboard(.interactively)` tracks a
    /// SLOW drag that travels down into the keyboard area (a fast flick only scrolls, and the default
    /// drag velocity is too fast to track) — the keyboard then follows the finger off screen.
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.2, thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(rawValue: 220), thenHoldForDuration: 0.2)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "keyboard did not dismiss")
    }

    /// Open History and count its rows — one per REAL LLM request in the stub container.
    private func historyRowCount(_ app: XCUIApplication) -> Int {
        openTab(app, "History")
        _ = app.cells.firstMatch.waitForExistence(timeout: 3)
        return app.cells.count
    }

    /// Generate the canned Say-it variants for `text` and wait for the cards.
    private func generateSayIt(_ app: XCUIApplication, text: String) -> XCUIElement {
        let input = field(app, "sayit.input")
        XCTAssertTrue(input.waitForExistence(timeout: 5), "Say-it input field not found")
        typeAndSubmit(app, field: input, text: text, buttonID: "sayit.action")
        let card = app.staticTexts[sayItCard]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "generated variants did not appear")
        return card
    }

    // MARK: Tests

    /// Generate on Say it → visit Get it → return: the SAME results must still be shown, with no
    /// regeneration (no processing state, still exactly one History row) and the input preserved.
    @MainActor
    func testSayItResultsSurviveTabSwitch() throws {
        let app = launchApp()
        let card = generateSayIt(app, text: "how do i say thanks")

        openTab(app, "Get it")
        openTab(app, "Say it")

        XCTAssertFalse(app.staticTexts[sayItProcessing].waitForExistence(timeout: 2),
                       "returning to Say it re-generated the phrases")
        XCTAssertTrue(card.exists, "the previous results are gone after a tab round-trip")
        XCTAssertEqual(fieldValue(field(app, "sayit.input")), "how do i say thanks")
        XCTAssertEqual(historyRowCount(app), 1, "a hidden extra request was made")
    }

    /// Edit the input WITHOUT pressing regenerate, leave, return: the field must show the text the
    /// visible results were generated from (the unsubmitted edit is dropped), results untouched.
    @MainActor
    func testSayItUnsubmittedEditRevertsOnReturn() throws {
        let app = launchApp()
        let card = generateSayIt(app, text: "thanks a lot")

        let input = field(app, "sayit.input")
        input.tap()
        input.typeText(" and more")           // edited, NOT submitted
        dismissKeyboard(app)
        XCTAssertNotEqual(fieldValue(input), "thanks a lot", "the edit should have changed the field")

        openTab(app, "Get it")
        openTab(app, "Say it")

        XCTAssertTrue(card.waitForExistence(timeout: 2), "results must survive the round-trip")
        XCTAssertEqual(fieldValue(field(app, "sayit.input")), "thanks a lot",
                       "an unsubmitted edit must revert so the input matches the shown results")
        XCTAssertFalse(app.staticTexts[sayItProcessing].exists)
    }

    /// The Say-it mode (What to say) and tone (Slang) must survive leaving and returning.
    @MainActor
    func testSayItModeAndToneSurviveTabSwitch() throws {
        let app = launchApp()
        let whatToSay = segment(app, "sayit.mode.whatToSay")
        XCTAssertTrue(whatToSay.waitForExistence(timeout: 5))
        whatToSay.tap()
        segment(app, "sayit.tone.slang").tap()

        openTab(app, "Get it")
        openTab(app, "Say it")

        XCTAssertTrue(segment(app, "sayit.mode.whatToSay").isSelected, "Say-it mode was not preserved")
        XCTAssertTrue(segment(app, "sayit.tone.slang").isSelected, "tone was not preserved")
    }

    /// Get it: translate a word, round-trip through Say it — the result, the input, and the
    /// Translate mode selection must all survive, with no re-request.
    @MainActor
    func testGetItModeAndResultSurviveTabSwitch() throws {
        let app = launchApp()
        openTab(app, "Get it")
        let translateSegment = segment(app, "getit.mode.translate")
        XCTAssertTrue(translateSegment.waitForExistence(timeout: 5))
        translateSegment.tap()                // default is Explain

        let input = field(app, "getit.input")
        XCTAssertTrue(input.waitForExistence(timeout: 5), "Get-it input field not found")
        typeAndSubmit(app, field: input, text: "bank", buttonID: "getit.action")

        let result = app.staticTexts["банк"]  // canned "understand" translation
        XCTAssertTrue(result.waitForExistence(timeout: 10), "translation did not appear")

        openTab(app, "Say it")
        openTab(app, "Get it")

        XCTAssertFalse(app.staticTexts[getItProcessing].waitForExistence(timeout: 2),
                       "returning to Get it re-ran the translation")
        XCTAssertTrue(result.exists, "the Get-it result is gone after a tab round-trip")
        XCTAssertEqual(fieldValue(field(app, "getit.input")), "bank")
        XCTAssertTrue(segment(app, "getit.mode.translate").isSelected, "Get-it mode was not preserved")
        XCTAssertEqual(historyRowCount(app), 1, "a hidden extra request was made")
    }

    /// See it: the Explain/Translate mode choice must survive a tab round-trip.
    @MainActor
    func testSeeItModeSurvivesTabSwitch() throws {
        let app = launchApp()
        openTab(app, "See it")
        let translate = segment(app, "seeit.mode.translate")
        XCTAssertTrue(translate.waitForExistence(timeout: 5))
        translate.tap()

        openTab(app, "Say it")
        openTab(app, "See it")

        XCTAssertTrue(segment(app, "seeit.mode.translate").isSelected, "See-it mode was not preserved")
    }
}
