//
//  FlashcardsUITests.swift
//  EnglishHelper — UITests
//
//  The Study dashboard and flashcard practice end to end on the stub data (two saved expressions, none
//  in flashcards): dashboard → Caught → swipe a phrase right into flashcards → back → Start → Show
//  answer → Good (a 10-minute learning step, so it comes back) → Show answer → Good (graduates) → done
//  → the dashboard counts the two answers. Plus: Move all, deleting from In flashcards, the paywall,
//  Fix cards, and look-alikes: merged when moved from Caught, or found and merged by Find duplicates.
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

        // Nothing in flashcards yet: the dashboard points to Caught.
        XCTAssertTrue(app.buttons["flashcards.openCaught"].waitForExistence(timeout: 5))
        attach(app, "dashboard-empty")
        app.buttons["study.caught"].tap()

        // Swipe right: the phrase moves into flashcards and leaves the list.
        XCTAssertTrue(app.navigationBars["Caught"].waitForExistence(timeout: 3))
        let row = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'I appreciate it'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        attach(app, "saved")
        row.swipeRight()
        let learn = app.buttons["Learn"]
        if learn.waitForExistence(timeout: 2) { learn.tap() }   // a short swipe only reveals the action
        XCTAssertTrue(row.waitForNonExistence(timeout: 3), "the phrase stayed in Caught")
        app.navigationBars["Caught"].buttons.element(boundBy: 0).tap()

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
        attach(app, "finished")
        app.buttons["Close"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["All done for today — come back tomorrow."].waitForExistence(timeout: 3))
        XCTAssertFalse(start.isEnabled)
        attach(app, "dashboard-after")

        // In flashcards: the phrase's status — recognition answered twice and graduated, recall untouched.
        app.buttons["study.studying"].tap()
        let studied = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'I appreciate it'")).firstMatch
        XCTAssertTrue(studied.waitForExistence(timeout: 3))
        let status = app.cells.containing(NSPredicate(
            format: "label CONTAINS 'Recognize: young, reviews: 2' AND label CONTAINS 'Recall: new, reviews: 0'")).firstMatch
        XCTAssertTrue(status.exists, "the card status isn't shown")
        attach(app, "in-flashcards")

        // Tapping the phrase shows the whole card — both sides and progress — without practising it.
        studied.tap()
        XCTAssertTrue(app.buttons["cardPreview.done"].waitForExistence(timeout: 3), "the card didn't open")
        XCTAssertTrue(app.staticTexts["Я ценю это"].exists)
        XCTAssertTrue(app.otherElements["cardPreview.progress"].exists || app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH 'Recognize: young'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["flashcards.rate.good"].exists, "a preview isn't practice")
        attach(app, "card-preview")
        app.buttons["cardPreview.done"].tap()
        XCTAssertTrue(status.waitForExistence(timeout: 3), "looking at the card changed its progress")
    }

    /// Caught → Move all (confirmed) empties the list; In flashcards then lists both phrases, and a
    /// swipe left deletes one.
    func testMoveAllThenDeleteFromFlashcards() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
        ]
        app.launch()
        app.tab("Study").tap()
        let caught = app.buttons["study.caught"]
        XCTAssertTrue(caught.waitForExistence(timeout: 5))
        caught.tap()

        let moveAll = app.buttons["caught.moveAll"]
        XCTAssertTrue(moveAll.waitForExistence(timeout: 3))
        moveAll.tap()
        let confirm = app.buttons["Move (2)"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        attach(app, "move-all-sheet")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Nothing yet"].waitForExistence(timeout: 3), "Caught didn't empty")
        app.navigationBars["Caught"].buttons.element(boundBy: 0).tap()

        let studying = app.buttons["study.studying"]
        XCTAssertTrue(studying.waitForExistence(timeout: 3))
        XCTAssertEqual(studying.label, "In flashcards: 2")
        studying.tap()
        XCTAssertTrue(app.navigationBars["In flashcards"].waitForExistence(timeout: 3))
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(app.cells.element(boundBy: 1).waitForNonExistence(timeout: 3), "the phrase wasn't deleted")
        app.navigationBars["In flashcards"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["study.studying"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["study.studying"].label, "In flashcards: 1")
    }

    /// Caught → From photos: the progress sheet runs over the photos (stubbed: two blank images, the
    /// stub model answers two cards), Done closes it and the caught cards are on the list.
    func testCatchCardsFromPhotos() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES", "-uiTestCatchPhotos",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
        ]
        app.launch()
        app.tab("Study").tap()
        let caught = app.buttons["study.caught"]
        XCTAssertTrue(caught.waitForExistence(timeout: 5))
        caught.tap()

        XCTAssertTrue(app.progressIndicators["catch.progress"].waitForExistence(timeout: 5))
        attach(app, "catch-running")
        let done = app.buttons["catch.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Cards: 2"].exists)
        attach(app, "catch-done")
        done.tap()

        let threshold = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'threshold'")).firstMatch
        XCTAssertTrue(threshold.waitForExistence(timeout: 3), "the caught cards aren't on the list")
    }

    /// In flashcards → Fix cards: the sheet counts the phrases, offers the modes, runs over every phrase, Done.
    func testFixCards() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
        ]
        app.launch()
        app.tab("Study").tap()
        app.buttons["study.caught"].tap()
        XCTAssertTrue(app.buttons["caught.moveAll"].waitForExistence(timeout: 3))
        app.buttons["caught.moveAll"].tap()
        app.buttons["Move (2)"].tap()
        app.navigationBars["Caught"].buttons.element(boundBy: 0).tap()
        app.buttons["study.studying"].tap()

        let menu = app.buttons["cards.transfer"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        app.buttons["Fix cards"].tap()
        let start = app.buttons["fix.all"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "no choice of mode before overwriting the cards")
        XCTAssertEqual(start.label, "All cards (2)")
        XCTAssertFalse(app.buttons["fix.incomplete"].exists, "the stub cards are complete")
        attach(app, "fix-modes")
        start.tap()
        let done = app.buttons["fix.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Phrases: 2 of 2"].exists)
        attach(app, "fix-done")
        done.tap()
        XCTAssertTrue(app.navigationBars["In flashcards"].waitForExistence(timeout: 3))
    }

    /// An empty Caught offers both ways to add a card; "Generate from a phrase" opens the new-card
    /// sheet (phrase on two lines, focused), and the generated card lands on the list.
    func testEmptyCaughtOffersBothWays() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
        ]
        app.launch()
        app.tab("Study").tap()
        app.buttons["study.caught"].tap()
        XCTAssertTrue(app.buttons["caught.moveAll"].waitForExistence(timeout: 3))
        app.buttons["caught.moveAll"].tap()
        app.buttons["Move (2)"].tap()

        let phrase = app.buttons["caught.empty.phrase"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 3), "the empty list doesn't offer a phrase")
        XCTAssertTrue(app.buttons["caught.empty.photos"].exists, "the empty list doesn't offer photos")
        attach(app, "caught-empty")
        phrase.tap()

        let field = app.textFields["newCard.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("to hit the roof")                         // focused at once
        attach(app, "new-card")
        app.buttons["newCard.generate"].tap()
        let card = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'to hit the roof'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "the generated card isn't in Caught")
    }

    /// A caught phrase that looks like one in flashcards asks before moving; Merge makes one card.
    func testCaughtLookAlikeMergesIntoFlashcards() {
        let app = openCaughtWithALookAlike()
        let merge = app.buttons["Merge"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5), "moving a look-alike didn't ask")
        attach(app, "look-alike")
        merge.tap()
        let lookAlike = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'I appreciate it!'")).firstMatch
        XCTAssertTrue(lookAlike.waitForNonExistence(timeout: 5), "the merged phrase stayed in Caught")
        app.navigationBars["Caught"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["study.studying"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["study.studying"].label, "In flashcards: 1")
    }

    /// Moved separately, the look-alike is found by In flashcards → Find duplicates: the same phrase and
    /// translation — an exact duplicate, merged without the model.
    func testFindDuplicatesMergesAGroup() {
        let app = openCaughtWithALookAlike()
        let separately = app.buttons["Move separately"]
        XCTAssertTrue(separately.waitForExistence(timeout: 5))
        separately.tap()
        app.navigationBars["Caught"].buttons.element(boundBy: 0).tap()
        let studying = app.buttons["study.studying"]
        XCTAssertTrue(studying.waitForExistence(timeout: 3))
        XCTAssertEqual(studying.label, "In flashcards: 2")
        studying.tap()

        let menu = app.buttons["cards.transfer"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        app.buttons["Find duplicates"].tap()
        let merge = app.buttons["dups.merge"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5), "no exact duplicate proposed")
        XCTAssertFalse(app.buttons["dups.check"].exists, "an exact duplicate needs no model")
        attach(app, "dups-found")
        merge.tap()
        XCTAssertTrue(app.staticTexts["Every group is sorted out"].waitForExistence(timeout: 5))
        attach(app, "dups-done")
        app.buttons["dups.done"].tap()
        XCTAssertTrue(app.cells.element(boundBy: 1).waitForNonExistence(timeout: 3), "the duplicate is still listed")
    }

    /// Don't merge: the two cards are linked as not duplicates — the card shows it, the next search
    /// leaves them be, and a full re-check shows them again — they're an exact duplicate (the same
    /// translation), a merge proposed without the model.
    func testDontMergeLinksTheCards() {
        let app = openCaughtWithALookAlike()
        let separately = app.buttons["Move separately"]
        XCTAssertTrue(separately.waitForExistence(timeout: 5))
        separately.tap()
        app.navigationBars["Caught"].buttons.element(boundBy: 0).tap()
        let studying = app.buttons["study.studying"]
        XCTAssertTrue(studying.waitForExistence(timeout: 3))
        studying.tap()

        openFindDuplicates(app)
        let keep = app.buttons["dups.keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dups.merge"].exists, "Merge and Don't merge side by side")
        attach(app, "dups-two-buttons")
        keep.tap()
        XCTAssertTrue(app.staticTexts["Every group is sorted out"].waitForExistence(timeout: 3))
        app.buttons["dups.done"].tap()

        // The card shows the link.
        let row = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'I appreciate it!'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        let links = app.staticTexts["cardPreview.notDuplicates"]                // its texts, combined
        XCTAssertTrue(links.waitForExistence(timeout: 3), "the card doesn't show its not-duplicate link")
        XCTAssertTrue(links.label.contains("«I appreciate it»"))
        attach(app, "card-not-duplicate")
        app.buttons["cardPreview.done"].tap()

        // The next search leaves them be; a full re-check shows them, an exact duplicate after all.
        openFindDuplicates(app)
        XCTAssertTrue(app.staticTexts["No duplicates found"].waitForExistence(timeout: 5))
        app.buttons["dups.full"].tap()
        XCTAssertTrue(app.buttons["dups.keep"].waitForExistence(timeout: 5), "the full re-check didn't bring them back")
        XCTAssertTrue(app.staticTexts["Marked \"not duplicates\""].exists)
        attach(app, "dups-full")
    }

    private func openFindDuplicates(_ app: XCUIApplication) {
        let menu = app.buttons["cards.transfer"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        app.buttons["Find duplicates"].tap()
    }

    /// Caught with "I appreciate it" moved into flashcards and "I appreciate it!" generated, then moved
    /// too (swipe right → Learn) — the app is left asking about the look-alike.
    private func openCaughtWithALookAlike() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
        ]
        app.launch()
        app.tab("Study").tap()
        let caught = app.buttons["study.caught"]
        XCTAssertTrue(caught.waitForExistence(timeout: 5))
        caught.tap()
        let original = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'I appreciate it'")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 3))
        swipeToLearn(original, in: app)
        XCTAssertTrue(original.waitForNonExistence(timeout: 3))

        app.buttons["caught.add"].tap()
        app.buttons["Generate from a phrase"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("I appreciate it!")
        app.buttons["Generate the card"].tap()
        let lookAlike = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'I appreciate it!'")).firstMatch
        XCTAssertTrue(lookAlike.waitForExistence(timeout: 5), "the generated card isn't in Caught")
        swipeToLearn(lookAlike, in: app)
        return app
    }

    private func swipeToLearn(_ row: XCUIElement, in app: XCUIApplication) {
        row.swipeRight()
        let learn = app.buttons["Learn"]
        if learn.waitForExistence(timeout: 2) { learn.tap() }   // a short swipe only reveals the action
    }

    /// The list's search finds a card by any field — here a word from its note.
    func testSearchFindsByAnyField() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
        ]
        app.launch()
        app.tab("Study").tap()
        app.buttons["study.caught"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3), "no search field")
        search.tap()
        search.typeText("благодарн")
        let found = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'I appreciate it'")).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 3))
        XCTAssertFalse(app.cells.containing(NSPredicate(format: "label BEGINSWITH 'No worries'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["caught.moveAll"].exists, "Move all would move more than what's shown")
        attach(app, "search")
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
