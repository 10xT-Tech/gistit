//
//  PaywallScreenshotUITests.swift
//  EnglishHelper — UITests
//
//  The subscription offer renders with the product loaded (local StoreKit configuration, no App
//  Store Connect round-trip) and is kept as a screenshot attachment — the App Review screenshot for
//  the subscription. Export: xcresulttool export attachments.
//

import XCTest
import StoreKitTest

final class PaywallScreenshotUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    func testPaywallShowsTheMonthlySubscription() throws {
        let session = try SKTestSession(configurationFileNamed: "GistIt")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true

        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestStubs", "-didCompleteOnboarding", "YES", "-didPrimeMic", "YES",
            "-interfaceLanguage", "en", "-studiedLanguage", "english", "-targetLanguage", "russian",
            "-AppleLanguages", "(en-GB)", "-AppleLocale", "en_GB",
        ]
        app.launch()

        // The reviewer's path in a sandbox build: Settings → Subscription → View subscription.
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        gear.tap()
        let view = app.buttons["settings.viewSubscription"]
        XCTAssertTrue(view.waitForExistence(timeout: 5), "Settings must offer the subscription in a sandbox build")
        view.tap()

        XCTAssertTrue(app.staticTexts["Gist It Pro"].firstMatch.waitForExistence(timeout: 10))
        // The product loaded: StoreKit shows its price on the purchase button.
        let priced = app.buttons.containing(NSPredicate(format: "label CONTAINS '2.99'")).firstMatch
        XCTAssertTrue(priced.waitForExistence(timeout: 15), "the subscription product didn't load")
        sleep(1)   // let the sheet settle

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "paywall"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
