//
//  LastScreenTests.swift
//  EnglishHelper — Tests
//
//  The app reopens on the screen it was closed on: what the stored value opens (a tab, the list open
//  on Study, a tab that no longer exists, a launch before onboarding), and what `ScreenMemory` keeps
//  as the user — or a link — moves between screens.
//

import Testing
import Foundation
import Presentation

@MainActor @Suite struct LastScreenTests {

    private func store() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "last-screen-\(UUID().uuidString)"))
    }

    /// A launch after the one that left `store` as it is.
    private func relaunch(_ store: UserDefaults, onboarded: Bool = true) -> ScreenMemory {
        ScreenMemory(store: store, onboarded: onboarded)
    }

    // MARK: What a stored value opens

    @Test func nothingStoredOpensSayIt() {
        #expect(LastScreen.opening(stored: nil, onboarded: true) == LastScreen(tab: "out"))
        #expect(LastScreen.initial.tab == "out")
    }

    @Test func everyMainTabIsOpenedAgain() {
        for tab in TabSwipe.order {
            #expect(LastScreen.opening(stored: tab, onboarded: true) == LastScreen(tab: tab))
        }
    }

    @Test func theListOpenOnStudyIsOpenedAgain() {
        #expect(LastScreen.opening(stored: "library/caught", onboarded: true)
                == LastScreen(tab: "library", studyList: .caught))
        #expect(LastScreen.opening(stored: "library/studying", onboarded: true)
                == LastScreen(tab: "library", studyList: .studying))
    }

    @Test func aTabThatNoLongerExistsOpensTheStartScreen() {
        #expect(LastScreen.opening(stored: "gone", onboarded: true) == .initial)
        #expect(LastScreen.opening(stored: "", onboarded: true) == .initial)
        #expect(LastScreen.opening(stored: "/caught", onboarded: true) == .initial)
        // The tab set changed: a tab of the old set isn't in the new one.
        #expect(LastScreen.opening(stored: "camera", onboarded: true, tabs: ["library", "out", "in"]) == .initial)
        #expect(LastScreen.opening(stored: "library/caught", onboarded: true, tabs: ["out", "in"]) == .initial)
    }

    @Test func anUnknownPlaceInsideATabOpensTheTabItself() {
        #expect(LastScreen.opening(stored: "library/card-42", onboarded: true) == LastScreen(tab: "library"))
        #expect(LastScreen.opening(stored: "in/caught", onboarded: true) == LastScreen(tab: "in"))
        #expect(LastScreen(tab: "in", studyList: .caught).studyList == nil)   // a list is Study's only
    }

    @Test func beforeOnboardingTheAppOpensOnTheStartScreen() {
        #expect(LastScreen.opening(stored: "history", onboarded: false) == .initial)
        #expect(LastScreen.opening(stored: "library/caught", onboarded: false) == .initial)
    }

    // MARK: What is kept between launches

    @Test func theFirstLaunchStartsOnSayIt() throws {
        let memory = relaunch(try store())
        #expect(memory.tab == "out")
        #expect(memory.studyList == nil)
    }

    @Test func theTabLeftOnIsTheTabOpenedNext() throws {
        let store = try store()
        for tab in TabSwipe.order {
            relaunch(store).tab = tab
            #expect(relaunch(store).tab == tab)
        }
    }

    @Test func theStudyListLeftOnIsOpenedNext() throws {
        let store = try store()
        let memory = relaunch(store)
        memory.tab = "library"
        memory.studyList = .caught
        #expect(relaunch(store).screen == LastScreen(tab: "library", studyList: .caught))

        memory.studyList = .studying
        #expect(relaunch(store).screen == LastScreen(tab: "library", studyList: .studying))

        memory.studyList = nil   // back to the dashboard
        #expect(relaunch(store).screen == LastScreen(tab: "library"))
    }

    @Test func leavingStudyClosesItsList() throws {
        let store = try store()
        let memory = relaunch(store)
        memory.tab = "library"
        memory.studyList = .caught
        memory.tab = "camera"
        memory.tab = "library"
        #expect(memory.studyList == nil)
        #expect(relaunch(store).screen == LastScreen(tab: "library"))
    }

    @Test func selectingTheTabAlreadyShownKeepsItsList() throws {
        let memory = relaunch(try store())
        memory.tab = "library"
        memory.studyList = .studying
        memory.tab = "library"
        #expect(memory.studyList == .studying)
    }

    @Test func aListIsOnlyKeptOnStudy() throws {
        let memory = relaunch(try store())
        memory.tab = "in"
        memory.studyList = .caught
        #expect(memory.studyList == nil)
    }

    /// A link is routed after the remembered screen was read: its screen is the one shown, the list
    /// that was open on Study is gone, and the link's screen is what the next launch opens.
    @Test func aLinkWinsOverTheRememberedScreen() throws {
        let store = try store()
        let before = relaunch(store)
        before.tab = "library"
        before.studyList = .caught

        let launch = relaunch(store)
        #expect(launch.screen == LastScreen(tab: "library", studyList: .caught))
        launch.tab = "camera"   // what RootView.handleURL does for a See it widget
        #expect(launch.screen == LastScreen(tab: "camera"))
        #expect(relaunch(store).screen == LastScreen(tab: "camera"))
    }

    @Test func aStoredTabThatNoLongerExistsIsForgotten() throws {
        let store = try store()
        store.set("gone", forKey: "lastScreen")
        #expect(relaunch(store).tab == "out")
        // …for good: the launch after it doesn't see the old value either.
        #expect(store.string(forKey: "lastScreen") == "out")
    }

    /// A launch that shows onboarding opens on the start screen, and what was stored before it doesn't
    /// come back once onboarding is done.
    @Test func onboardingStartsOnSayItAndForgetsWhatWasStored() throws {
        let store = try store()
        relaunch(store).tab = "history"

        let first = relaunch(store, onboarded: false)
        #expect(first.screen == .initial)
        #expect(relaunch(store).screen == .initial)

        first.tab = "in"   // the user moves on after onboarding
        #expect(relaunch(store).tab == "in")
    }
}
