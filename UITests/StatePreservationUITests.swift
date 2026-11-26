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
//  And through ENDING THE APP AND OPENING IT AGAIN (GST-16): it opens on the screen it was closed on —
//  the main tab, the list open on Study, the mode chosen on Get it / See it; a deep link wins over
//  that screen; a practice session, Settings, the paywall, an open card and an Online session start
//  fresh. `terminate()` ends the app the way iOS does behind the screen (no warning to the app).
//

import XCTest

final class StatePreservationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launch with deterministic stubs, onboarding skipped, and a pinned EN interface so the
    /// label-based queries below are stable regardless of the simulator's locale.
    /// - `reopening`: the app was ended and is opened AGAIN inside one test — what the launch before
    ///   wrote is still there (`-uiTestKeepPrefs`; without it every launch starts from nothing).
    /// - `pinModes: false`: the modes are read from what is stored, not pinned to the defaults.
    /// - `link`: the app is opened by this deep link (a Lock Screen widget's tap).
    private func launchApp(reopening: Bool = false, pinModes: Bool = true, extra: [String] = [],
                           link: URL? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs",
            "-didCompleteOnboarding", "YES",
            "-didPrimeMic", "YES",
            "-interfaceLanguage", "en",
            "-studiedLanguage", "english",
            "-targetLanguage", "russian",
            "-toneOfVoice", "casual",
        ]
        if pinModes {
            // Modes/tone are persisted; the argument domain pins each launch's READS to the defaults,
            // and under -uiTestStubs the app WRITES them to an ephemeral suite wiped every launch
            // (Presentation/Support/Prefs.swift) — so test taps never leak into the next test or
            // into the real app's saved preferences on this simulator.
            app.launchArguments += [
                "-sayItMode", "howToSay",
                "-getItMode", "explain",
                "-seeItMode", "explain",
            ]
        }
        if reopening { app.launchArguments.append("-uiTestKeepPrefs") }
        app.launchArguments += extra
        if let link { app.open(link) } else { app.launch() }
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

    // MARK: Ending the app and opening it again (GST-16)

    /// End the app (as iOS does behind the screen, or the user in the app switcher) and open it again.
    private func reopen(_ app: XCUIApplication, pinModes: Bool = true, extra: [String] = [],
                        link: URL? = nil) -> XCUIApplication {
        app.terminate()
        return launchApp(reopening: true, pinModes: pinModes, extra: extra, link: link)
    }

    /// The first row of the Caught list in the stub data — there once the list is loaded.
    private func caughtRow(_ app: XCUIApplication) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label BEGINSWITH 'I appreciate it'")).firstMatch
    }

    /// The Online transcript pane holding the stub session's first sentence.
    private func liveText(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Mind the gap.'")).firstMatch
    }

    private func openCaught(_ app: XCUIApplication) {
        openTab(app, "Study")
        let caught = app.buttons["study.caught"]
        XCTAssertTrue(caught.waitForExistence(timeout: 5), "the Study dashboard didn't load")
        caught.tap()
        XCTAssertTrue(app.navigationBars["Caught"].waitForExistence(timeout: 5), "Caught didn't open")
    }

    private func goBack(_ app: XCUIApplication, from title: String) {
        app.navigationBars[title].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["study.caught"].waitForExistence(timeout: 5), "back didn't lead to the dashboard")
    }

    /// Closed on any main tab, the app opens on that tab. Say it — where a first launch starts — comes
    /// last, after another tab was remembered: it is opened because it was left on, not by default.
    @MainActor
    func testEachMainTabIsReopened() throws {
        var app = launchApp()
        for name in ["Study", "See it", "Get it", "History", "Say it"] {
            openTab(app, name)
            app = reopen(app)
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10),
                          "closed on \(name), the app opened on another screen")
            XCTAssertTrue(app.tab(name).isSelected, "the tab bar doesn't show \(name) as selected")
        }
    }

    /// Study: closed in Caught or In flashcards, the app opens in that list (filled, with a way back
    /// to the dashboard); closed on the dashboard — on the dashboard; and a list left for another tab
    /// isn't waiting on Study.
    @MainActor
    func testStudyListIsReopened() throws {
        var app = launchApp()
        openCaught(app)
        app = reopen(app)
        XCTAssertTrue(app.navigationBars["Caught"].waitForExistence(timeout: 10), "Caught was not reopened")
        XCTAssertTrue(app.tab("Study").isSelected)
        XCTAssertTrue(caughtRow(app).waitForExistence(timeout: 5), "the reopened list is empty")

        goBack(app, from: "Caught")
        app.buttons["study.studying"].tap()
        XCTAssertTrue(app.navigationBars["In flashcards"].waitForExistence(timeout: 5))
        app = reopen(app)
        XCTAssertTrue(app.navigationBars["In flashcards"].waitForExistence(timeout: 10),
                      "In flashcards was not reopened")

        goBack(app, from: "In flashcards")
        app = reopen(app)
        XCTAssertTrue(app.buttons["study.caught"].waitForExistence(timeout: 10), "the dashboard was not reopened")
        XCTAssertFalse(app.navigationBars["In flashcards"].exists, "a list the user went back from was reopened")

        openCaught(app)
        openTab(app, "Say it")
        app = reopen(app)
        XCTAssertTrue(app.navigationBars["Say it"].waitForExistence(timeout: 10))
        openTab(app, "Study")
        XCTAssertTrue(app.buttons["study.caught"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Caught"].exists, "a list left for another tab came back")
    }

    /// Get it / See it: the mode chosen on the selector is the mode the screen opens in.
    @MainActor
    func testGetItAndSeeItModesAreReopened() throws {
        var app = launchApp(pinModes: false)
        openTab(app, "Get it")
        let getItTranslate = segment(app, "getit.mode.translate")
        XCTAssertTrue(getItTranslate.waitForExistence(timeout: 5))
        XCTAssertFalse(getItTranslate.isSelected, "Explain is where Get it starts")
        getItTranslate.tap()
        openTab(app, "See it")
        let seeItTranslate = segment(app, "seeit.mode.translate")
        XCTAssertTrue(seeItTranslate.waitForExistence(timeout: 5))
        seeItTranslate.tap()

        app = reopen(app, pinModes: false)
        XCTAssertTrue(app.navigationBars["See it"].waitForExistence(timeout: 10), "See it was not reopened")
        XCTAssertTrue(segment(app, "seeit.mode.translate").isSelected, "See it didn't open in its mode")
        openTab(app, "Get it")
        XCTAssertTrue(segment(app, "getit.mode.translate").isSelected, "Get it didn't open in its mode")

        app = reopen(app, pinModes: false)
        XCTAssertTrue(app.navigationBars["Get it"].waitForExistence(timeout: 10), "Get it was not reopened")
        XCTAssertTrue(segment(app, "getit.mode.translate").isSelected, "Get it didn't open in its mode")
    }

    /// A deep link wins over the remembered screen, on a cold start too: closed in Caught, opened by
    /// the "Get it — Translate" widget, the app shows Get it in Translate — and Caught isn't waiting on
    /// Study. The link's screen is then the one the next launch opens; its mode was the link's only.
    @MainActor
    func testDeepLinkWinsOverTheRememberedScreen() throws {
        var app = launchApp()
        openCaught(app)

        app = reopen(app, link: URL(string: "englishhelper://getit-translate")!)
        XCTAssertTrue(app.navigationBars["Get it"].waitForExistence(timeout: 10),
                      "the link didn't open its screen")
        XCTAssertTrue(app.tab("Get it").isSelected)
        XCTAssertTrue(segment(app, "getit.mode.translate").isSelected, "the link didn't set its mode")
        XCTAssertFalse(app.navigationBars["Caught"].exists, "the remembered screen is shown under a link")

        app = reopen(app)
        XCTAssertTrue(app.navigationBars["Get it"].waitForExistence(timeout: 10),
                      "the screen a link opened was not the one reopened")
        XCTAssertTrue(segment(app, "getit.mode.explain").isSelected, "a link's mode replaced the chosen one")
        openTab(app, "Study")
        XCTAssertTrue(app.buttons["study.caught"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Caught"].exists, "the list closed by a link came back")
    }

    /// A practice session isn't reopened: closed in the middle of one, the app opens on the Study
    /// dashboard.
    @MainActor
    func testPracticeSessionStartsFresh() throws {
        var app = launchApp()
        openCaught(app)
        app.buttons["caught.moveAll"].tap()
        XCTAssertTrue(app.buttons["caught.empty.phrase"].waitForExistence(timeout: 10), "the move didn't finish")
        goBack(app, from: "Caught")
        app.buttons["flashcards.start"].tap()
        XCTAssertTrue(app.buttons["flashcards.reveal"].waitForExistence(timeout: 5), "practice didn't start")

        app = reopen(app)
        XCTAssertTrue(app.buttons["study.caught"].waitForExistence(timeout: 10), "Study was not reopened")
        XCTAssertTrue(app.tab("Study").isSelected)
        XCTAssertFalse(app.buttons["flashcards.reveal"].exists, "a practice session was reopened")
    }

    /// Settings and an open card aren't reopened: the app opens on the screen under them.
    @MainActor
    func testSettingsAndAnOpenCardStartFresh() throws {
        var app = launchApp()
        openTab(app, "History")
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings didn't open")

        app = reopen(app)
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10), "History was not reopened")
        XCTAssertFalse(app.navigationBars["Settings"].exists, "Settings was reopened")

        // A card opens from In flashcards: move the phrases there first.
        openCaught(app)
        app.buttons["caught.moveAll"].tap()
        XCTAssertTrue(app.buttons["caught.empty.phrase"].waitForExistence(timeout: 10), "the move didn't finish")
        goBack(app, from: "Caught")
        app.buttons["study.studying"].tap()
        let row = caughtRow(app)   // the same phrase, now in flashcards
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["cardPreview.done"].waitForExistence(timeout: 5), "the card didn't open")

        app = reopen(app)
        XCTAssertTrue(app.navigationBars["In flashcards"].waitForExistence(timeout: 10),
                      "In flashcards was not reopened")
        XCTAssertFalse(app.buttons["cardPreview.done"].exists, "an open card was reopened")
    }

    /// A running Online session isn't reopened: Get it opens in Online — the mode chosen — with the
    /// microphone off.
    @MainActor
    func testOnlineSessionStartsFresh() throws {
        var app = launchApp(pinModes: false)
        openTab(app, "Get it")
        let online = segment(app, "getit.mode.online")
        XCTAssertTrue(online.waitForExistence(timeout: 5))
        online.tap()
        let listen = app.buttons["Listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 5))
        listen.tap()
        XCTAssertTrue(liveText(app).waitForExistence(timeout: 10), "the session didn't start")
        XCTAssertEqual(listen.value as? String, "Listening")

        app = reopen(app, pinModes: false)
        XCTAssertTrue(app.navigationBars["Get it"].waitForExistence(timeout: 10), "Get it was not reopened")
        XCTAssertTrue(segment(app, "getit.mode.online").isSelected, "Get it didn't open in Online")
        XCTAssertEqual(app.buttons["Listen"].value as? String, "Ready", "an Online session was reopened")
        XCTAssertFalse(liveText(app).exists, "the ended session's text is back")
    }

    /// The paywall isn't reopened: the app opens on the screen it was over.
    @MainActor
    func testPaywallStartsFresh() throws {
        let freePlan = ["-uiTestFreePlan"]
        var app = launchApp(pinModes: false, extra: freePlan)
        openTab(app, "Get it")
        let online = segment(app, "getit.mode.online")
        XCTAssertTrue(online.waitForExistence(timeout: 5))
        online.tap()
        app.buttons["Listen"].tap()   // Online is Pro: on the free plan Listen opens the offer
        XCTAssertTrue(app.staticTexts["Gist It Pro"].firstMatch.waitForExistence(timeout: 5),
                      "the paywall didn't open")

        app = reopen(app, pinModes: false, extra: freePlan)
        XCTAssertTrue(app.navigationBars["Get it"].waitForExistence(timeout: 10), "Get it was not reopened")
        XCTAssertFalse(app.staticTexts["Gist It Pro"].exists, "the paywall was reopened")
    }

    /// A launch that shows onboarding doesn't open the remembered screen — and the stored value is
    /// dropped. (Onboarding itself isn't completed here: that writes to the app's real preferences.)
    @MainActor
    func testOnboardingIsShownWhateverWasRemembered() throws {
        var app = launchApp()
        openTab(app, "History")
        app.terminate()

        app = XCUIApplication()
        app.launchArguments += ["-uiTestStubs", "-uiTestKeepPrefs", "-didCompleteOnboarding", "NO",
                                "-interfaceLanguage", "en"]
        app.launch()
        XCTAssertFalse(app.tab("History").waitForExistence(timeout: 3), "the main screens opened before onboarding")
        app.terminate()

        // With onboarding behind: the screen from before it is forgotten, the app starts on Say it.
        app = launchApp(reopening: true)
        XCTAssertTrue(app.navigationBars["Say it"].waitForExistence(timeout: 10),
                      "the screen remembered before onboarding came back after it")
    }
}
