//
//  TabBarQuery.swift
//  EnglishHelper — UITests
//
//  The main tab bar is the app's own GlassTabBar (not a system UITabBar — the screens live side by
//  side so they can be swiped), so `app.tabBars` finds nothing. Its buttons carry the identifier
//  "tab.<id>" and the localized title as their label.
//

import XCTest

extension XCUIApplication {
    /// The tab bar button titled `name` (e.g. "Get it").
    func tab(_ name: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND label == %@", name)).firstMatch
    }
}
