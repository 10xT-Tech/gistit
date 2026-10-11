//
//  EnglishHelperApp.swift
//  EnglishHelper — App (entry point)
//

import SwiftUI
import WidgetKit
import Domain
import Adapters
import DesignSystem
import Presentation

@main
struct EnglishHelperApp: App {
    /// Async composition root: `App.init` stays trivial (reachability wiring only), and the heavy
    /// boot — opening the SwiftData store (+ migrations) and building the graph — runs OFF the main
    /// thread behind a plain launch screen, so cold-launch time no longer grows with store size.
    @State private var boot = AppBoot()
    /// UI reachability state (@Observable) — drives the offline banner + auto-retry in RootView.
    private let network: NetworkMonitor
    /// Platform reachability (NWPathMonitor, Adapters layer). Retained here so it stays alive; its
    /// thread-safe `isReachable` backs the LLM client's fast-offline pre-check, and its updates are
    /// forwarded to `network` for the UI.
    private let reachability: ReachabilityMonitor
    /// Product analytics (Amplitude). Created here — the SDK starts its session / app-lifecycle
    /// observers on init, so it must exist from launch — and handed to `bootLive`. Nil = off.
    private let analytics: AmplitudeTracker?

    init() {
        let config = AppConfig.load()
        // Sentry (crash & error reporting) first, so a crash anywhere below is caught. Off without a
        // DSN (fresh clone / CI) and under tests (UI + unit) — test runs must never page anyone.
        if !Self.isUITest, !Self.isUnitTestHost, let dsn = config.sentryDSN {
            SentryCrashReporter.start(dsn: dsn)
        }
        let networkUI = NetworkMonitor()
        network = networkUI
        // NWPathMonitor (Adapters) pushes every path change to the UI monitor on the main actor.
        reachability = ReachabilityMonitor { online, constrained in
            Task { @MainActor in networkUI.update(isOnline: online, isConstrained: constrained) }
        }
        // Off when the API key isn't configured (fresh clone / CI), under XCUITest (deterministic
        // runs), and when hosting unit tests — test runs must never land in the GistIt dashboard.
        analytics = Self.isUITest || Self.isUnitTestHost
            ? nil
            : config.amplitudeAPIKey.map(AmplitudeTracker.init(apiKey:))
    }

    /// True when launched by the XCUITest suite (`-uiTestStubs`): boot deterministic stubs and skip
    /// the launch side effects that could pop system dialogs mid-test (notification permission).
    private static var isUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestStubs")
    }

    /// True when the app is only the host process for the unit-test bundle.
    private static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            if let deps = boot.deps {
                RootView(
                    out: deps.out,               // "Out": native intent → studied-language variants
                    inbound: deps.inbound,       // "In": studied-language text → translate / explain
                    photo: deps.photo,
                    library: deps.library,
                    history: deps.history,
                    settings: deps.settings,
                    subscription: deps.subscription,
                    degradedStorage: deps.degradedStorage,
                    network: network,
                    consumeShared: {
                        // Bridge the App-Group payload (App target) to the Presentation route type.
                        let payload = SharedInbox.consume()
                        if payload != nil { ShareSupport.clearShareNotification() }
                        switch payload {
                        case .text(let text): return .explainText(text)
                        case .image(let data): return .explainImage(data)
                        case nil: return nil
                        }
                    },
                    consumeLaunchURL: { boot.takePendingURL() }
                )
                .task {
                    guard !Self.isUITest else { return }   // no permission prompts under XCUITest
                    // Mirror the interface language to the App Group + ensure notification permission, so the
                    // Share Extension can post a tappable, localized "open the app" notification (iOS
                    // bars the extension from foregrounding the app directly).
                    await ShareSupport.prepare()
                    // Force already-placed Lock Screen widgets to re-render with this build's code. Without
                    // this they keep a CACHED render after an app update (our widgets use a `.never` refresh
                    // policy, so iOS never re-fetches their timeline on its own).
                    WidgetCenter.shared.reloadAllTimelines()
                }
            } else {
                // Plain launch surface while the graph boots (typically well under a second). A widget
                // deep link cold-launching the app can land HERE, before RootView exists — buffer it;
                // RootView consumes it in its launch task.
                ScreenBackground()
                    .onOpenURL { boot.pendingURL = $0 }
                    .task {
                        let probe = reachability
                        await boot.start(
                            uiTestStubs: Self.isUITest,
                            analytics: analytics,
                            isReachable: { [weak probe] in probe?.isReachable ?? true }
                        )
                    }
            }
        }
    }
}

/// Boots the dependency graph asynchronously and holds the view models RootView needs. The view
/// models are created exactly ONCE here (not in `body`, which re-evaluates), preserving screen state.
@MainActor
@Observable
private final class AppBoot {
    struct Deps {
        let out: VoiceViewModel
        let inbound: InViewModel
        let photo: PhotoTranslateViewModel
        let library: StudyListViewModel
        let history: HistoryViewModel
        let settings: SettingsViewModel
        let subscription: SubscriptionState
        let degradedStorage: Bool
    }

    private(set) var deps: Deps?
    /// Deep-link URL that arrived while the launch screen was up; single-consumed by RootView.
    var pendingURL: URL?

    func takePendingURL() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }

    func start(uiTestStubs: Bool, analytics: (any AnalyticsTracking)?,
               isReachable: @escaping @Sendable () -> Bool) async {
        guard deps == nil else { return }
        let container: AppContainer
        if uiTestStubs {
            container = AppContainer.bootUITestStubs()
        } else {
            // `bootLive` already degrades a failed on-disk store to an in-memory one (flagged via
            // `usingFallbackStore` → a visible banner), so the only way it throws is a total SwiftData
            // failure; mocks are the last-resort so the app still opens. Detached: the store open (+
            // any migration) must not block the main thread behind the launch screen.
            container = await Task.detached(priority: .userInitiated) {
                do {
                    return try AppContainer.bootLive(isReachable: isReachable, analytics: analytics)
                } catch {
                    return AppContainer.bootMock()
                }
            }.value
        }
        deps = Deps(
            out: container.makeVoiceViewModel(),
            inbound: container.makeInViewModel(),
            photo: container.makePhotoTranslateViewModel(),
            library: container.makeStudyListViewModel(),
            history: container.makeHistoryViewModel(),
            settings: container.makeSettingsViewModel(),
            subscription: container.makeSubscriptionState(),
            degradedStorage: container.usingFallbackStore
        )
        // Best-effort, off the launch path: delete session recordings no history row references
        // (crash mid-session / fallback store / failed saves would otherwise leak them forever).
        Task.detached(priority: .utility) { await container.sweepOrphanedRecordings() }
    }
}
