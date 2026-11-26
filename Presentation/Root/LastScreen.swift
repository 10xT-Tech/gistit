//
//  LastScreen.swift
//  EnglishHelper — Presentation
//
//  The app opens on the screen it was closed on — swiped away in the app switcher, or ended by iOS
//  behind the screen. Remembered: the main tab and, on Study, the list pushed from the dashboard
//  (Caught / In flashcards). The mode chosen on Say it / Get it / See it is remembered by those
//  screens themselves (`selectMode`). Everything else starts fresh: a practice session, the paywall,
//  Settings, an Online session, any sheet, an open card.
//
//  Kept in UserDefaults, not `@SceneStorage`: iOS discards a scene's stored state when the user swipes
//  the app away, and that is the main case here. Written on every change (the app gets no reliable
//  "about to be ended" moment).
//
//  A link — a Lock Screen widget, the Share sheet, a Live Activity — wins by coming AFTER: the
//  remembered screen is only where the app starts, and RootView mounts no screen until the launch's
//  own link has been routed.
//

import Foundation
import Observation

/// A place the app can open on: a main tab and, on Study, the list pushed from its dashboard.
public struct LastScreen: Equatable, Sendable {
    /// The lists pushed from the Study dashboard.
    public enum StudyList: String, Sendable { case caught, studying }

    /// A main tab's id — one of `TabSwipe.order`.
    public let tab: String
    /// The list open on Study; nil = the dashboard. Always nil on another tab.
    public let studyList: StudyList?

    static let studyTab = "library"
    /// Where the app opens with nothing remembered: Say it.
    public static let initial = LastScreen(tab: "out")

    public init(tab: String, studyList: StudyList? = nil) {
        self.tab = tab
        self.studyList = tab == Self.studyTab ? studyList : nil
    }

    /// The stored form: the tab's id, then "/" and the list when one is open ("library/caught").
    var stored: String { studyList.map { "\(tab)/\($0.rawValue)" } ?? tab }

    /// THE one place that decides what the app opens on — a later rule (say, back to the start after
    /// a day away) belongs here. `stored` is what the last launch left. Before onboarding is done the
    /// app opens on the start screen whatever is stored; a tab that no longer exists (the tab set
    /// changes between versions) gives the start screen too, an unknown list its tab's own root.
    public static func opening(stored: String?, onboarded: Bool, tabs: [String] = TabSwipe.order) -> LastScreen {
        guard onboarded, let stored else { return .initial }
        let parts = stored.split(separator: "/", maxSplits: 1).map(String.init)
        guard let tab = parts.first, tabs.contains(tab) else { return .initial }
        return LastScreen(tab: tab, studyList: parts.count > 1 ? StudyList(rawValue: parts[1]) : nil)
    }
}

/// The screen the app is on, kept for the next launch. RootView owns the one instance; the tab bar,
/// the tab swipe and every route (a link, "Explain" from another screen) go through `tab`, the Study
/// dashboard through `studyList`.
@MainActor
@Observable
public final class ScreenMemory {
    public private(set) var screen: LastScreen {
        didSet { if screen != oldValue { save() } }
    }
    @ObservationIgnored private let store: UserDefaults

    static let storageKey = "lastScreen"

    /// The app's own: its preferences store, and whether onboarding was completed before this launch.
    public convenience init() {
        self.init(store: Prefs.store, onboarded: OnboardingStore.wasCompleted)
    }

    public init(store: UserDefaults, onboarded: Bool) {
        self.store = store
        let stored = store.string(forKey: Self.storageKey)
        screen = LastScreen.opening(stored: stored, onboarded: onboarded)
        // What is stored is always the screen shown: a value that wasn't used must not come back at
        // the launch after this one.
        if stored != screen.stored { save() }
    }

    /// The selected main tab. Leaving Study closes its list, as leaving any tab resets what was
    /// pushed there; selecting the tab already shown changes nothing.
    public var tab: String {
        get { screen.tab }
        set { if newValue != screen.tab { screen = LastScreen(tab: newValue) } }
    }

    /// The list pushed from the Study dashboard (nil = the dashboard itself).
    public var studyList: LastScreen.StudyList? {
        get { screen.studyList }
        set { screen = LastScreen(tab: screen.tab, studyList: newValue) }
    }

    private func save() { store.set(screen.stored, forKey: Self.storageKey) }
}
