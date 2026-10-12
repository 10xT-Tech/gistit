//
//  RootView.swift
//  EnglishHelper — Presentation
//
//  App shell: tab bar (Liquid Glass) + global theme + the Settings sheet.
//  Order: Изучаю · Смотреть/See · Сказать/Say (center, default) · Понять/Get · История.
//  "Сказать"/Say it (RU intent → 3 English variants, voice or text) and "Понять"/Get it (translate
//  OR explain an English expression into the native language) are the two comprehension directions;
//  "Смотреть"/See it is the photo translator.
//

import SwiftUI

public struct RootView: View {
    @State private var out: VoiceViewModel
    @State private var inbound: InViewModel
    @State private var photo: PhotoTranslateViewModel
    @State private var library: StudyListViewModel
    @State private var history: HistoryViewModel
    @State private var settings: SettingsViewModel
    @State private var subscription: SubscriptionState

    @State private var theme = ThemeStore()
    @State private var language = LanguageStore()
    @State private var studied = StudiedLanguageStore()
    @State private var target = TargetLanguageStore()
    @State private var ui = AppUIState()
    @State private var onboarding = OnboardingStore()
    @State private var network: NetworkMonitor
    @State private var selection = "out"
    @Environment(\.scenePhase) private var scenePhase

    /// True when persistence fell back to an in-memory store — changes this session won't be saved.
    private let degradedStorage: Bool
    /// Pulls the next item shared INTO the app via the iOS Share sheet (App-Group backed), or nil.
    /// Injected by the App composition root, which owns the App-Group reader. Default: nothing shared.
    private let consumeShared: () -> SharedRoute?
    /// Pulls a deep-link URL that arrived BEFORE this view existed (a widget tap cold-launching the
    /// app lands while the async boot splash is up), or nil. Single-consume; default: none.
    private let consumeLaunchURL: () -> URL?

    public init(
        out: VoiceViewModel,
        inbound: InViewModel,
        photo: PhotoTranslateViewModel,
        library: StudyListViewModel,
        history: HistoryViewModel,
        settings: SettingsViewModel,
        subscription: SubscriptionState = SubscriptionState(),
        degradedStorage: Bool = false,
        network: NetworkMonitor = NetworkMonitor(),
        consumeShared: @escaping () -> SharedRoute? = { nil },
        consumeLaunchURL: @escaping () -> URL? = { nil }
    ) {
        self.out = out
        self.inbound = inbound
        self.photo = photo
        self.library = library
        self.history = history
        self.settings = settings
        self.subscription = subscription
        self.degradedStorage = degradedStorage
        self.network = network
        self.consumeShared = consumeShared
        self.consumeLaunchURL = consumeLaunchURL
    }

    public var body: some View {
        @Bindable var ui = ui
        Group {
            if onboarding.isComplete {
                // Order must match `TabSwipe.order` — each screen swipes to its neighbours.
                TabView(selection: $selection) {
                    Tab(Loc.t("Изучаю", "Study"), systemImage: "rectangle.stack", value: "library") {
                        StudyListView(model: library)
                            .tabSwipe("library") { selection = $0 }
                    }
                    Tab(Loc.t("Смотреть", "See it"), systemImage: "camera", value: "camera") {
                        PhotoTranslateView(model: photo)
                            .tabSwipe("camera") { selection = $0 }
                    }
                    Tab(Loc.t("Сказать", "Say it"), systemImage: "mic.fill", value: "out") {
                        VoiceView(model: out)
                            .tabSwipe("out") { selection = $0 }
                    }
                    Tab(Loc.t("Понять", "Get it"), systemImage: "character.bubble", value: "in") {
                        InView(model: inbound)
                            .tabSwipe("in") { selection = $0 }
                    }
                    Tab(Loc.t("История", "History"), systemImage: "clock.arrow.circlepath", value: "history") {
                        HistoryView(model: history)
                            .tabSwipe("history") { selection = $0 }
                    }
                }
                .safeAreaInset(edge: .top) {
                    VStack(spacing: 0) {
                        if !network.isOnline { offlineBanner }
                        if degradedStorage { degradedStorageBanner }
                    }
                }
                // Auto-retry on reconnect: when the link returns, replay whatever failed offline — each
                // view model no-ops unless it's actually sitting on an offline failure. Zero taps.
                .onChange(of: network.isOnline) { wasOnline, isOnline in
                    guard isOnline, !wasOnline else { return }
                    out.retryOnReconnect()
                    inbound.retryOnReconnect()
                    photo.retryOnReconnect()
                }
                // iOS Share sheet → scenario. The extension wakes us via the `englishhelper://` scheme;
                // becoming active is the fallback if that launch was blocked. Single-consume either way.
                .onOpenURL { handleURL($0) }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    handleShared()   // warm foreground (already-running app)
                    Task { await subscription.refresh() }   // a renewal / expiry while we were away
                }
                .task {
                    #if DEBUG
                    // Screenshots / UI tests: open the subscription offer or Settings straight away.
                    if ProcessInfo.processInfo.arguments.contains("-showPaywall") { ui.showPaywall = true }
                    if ProcessInfo.processInfo.arguments.contains("-showSettings") { ui.showSettings = true }
                    #endif
                    await subscription.start()
                }
                .task {
                    // Cold launch (onChange won't fire for the initial active state). A widget URL
                    // that arrived while the boot splash was up is buffered by the App — route it now.
                    if let url = consumeLaunchURL() { handleURL(url) }
                    handleShared()
                }
                // Rebuild ONLY the tab content when the interface language changes — re-running every
                // screen's `Loc.t(...)`. Scoped here (not the whole body) so the Settings sheet and
                // `@State` survive: switching language live keeps the sheet open instead of dismissing.
                // TRADE-OFF: this discards transient view-local @State inside the tabs (e.g. a half-built
                // export share) — acceptable since changing language mid-action is rare and deliberate.
                .id(language.language)
                .environment(ui)
                .environment(subscription)
                .environment(\.locale, language.locale)
                // "Explain" from See it / History: switch to Get it and run it in Explain mode.
                .onChange(of: ui.pendingExplain) { _, request in
                    guard let request else { return }
                    selection = "in"
                    inbound.startExplain(text: request.text, alternatives: request.alternatives)
                    ui.pendingExplain = nil
                }
                .sheet(isPresented: $ui.showSettings) {
                    SettingsView(model: settings, theme: theme, language: language, studied: studied,
                                 target: target) {
                        ui.showSettings = false
                    }
                    .environment(\.locale, language.locale)
                    .environment(subscription)
                }
                .sheet(isPresented: $ui.showPaywall) {
                    PaywallView()
                        .environment(subscription)
                        .environment(\.locale, language.locale)
                }
            } else {
                // First launch: pick languages before the app opens. Starts in the system language
                // (or English) via `LanguageStore.effective`; `.id` re-renders it live on change.
                OnboardingView(language: language, studied: studied, target: target) {
                    // Lock in all three choices (even if left at the system defaults), then dismiss.
                    UserDefaults.standard.set(language.language.rawValue, forKey: AppLanguage.storageKey)
                    UserDefaults.standard.set(studied.language.rawValue, forKey: StudiedLanguage.storageKey)
                    UserDefaults.standard.set(target.language.rawValue, forKey: TargetLanguage.storageKey)
                    onboarding.complete()
                }
                .id(language.language)
                .environment(\.locale, language.locale)
            }
        }
        .preferredColorScheme(theme.colorScheme)
    }

    /// Route an `englishhelper://` deep link to its scenario. Lock Screen widgets deep-link straight
    /// to a scenario (the host carries the destination + mode); the Share extension uses host
    /// "share" (and legacy URLs) → fall through to the App-Group consume. Idempotent on purpose:
    /// iOS 26 can fire this twice per tap, and re-selecting the same tab / mode is a no-op.
    /// `routeMode` (not `selectMode`) keeps these routed mode changes session-only — they must not
    /// overwrite the mode the user explicitly chose on the on-screen selector.
    private func handleURL(_ url: URL) {
        guard url.scheme == "englishhelper" else { return }
        switch url.host {
        case "seeit", "seeit-translate":
            selection = "camera"
            photo.routeMode(url.host == "seeit-translate" ? .translate : .explain)
            if CameraPicker.isAvailable { photo.cameraTapped() }   // open the camera straight away
        case "getit", "getit-translate":
            selection = "in"
            inbound.routeMode(url.host == "getit-translate" ? .translate : .explain)
            inbound.beginVoiceInput()                              // turn the mic on for input
        case "getit-online":
            selection = "in"
            inbound.routeMode(.online)
            inbound.beginLiveInput()                               // start the live session hands-free
        case "sayit", "sayit-what":
            selection = "out"
            out.routeMode(url.host == "sayit-what" ? .whatToSay : .howToSay)
            out.beginVoiceInput()
        default:
            handleShared()
        }
    }

    /// Consume a pending shared item (from the Share Extension) and route it to its scenario:
    /// text → Get it / Explain, image → See it / Explain. No-ops when nothing is pending.
    /// `routeMode`: session-only, same as handleURL.
    private func handleShared() {
        guard let route = consumeShared() else { return }
        switch route {
        case .explainText(let text):
            selection = "in"
            inbound.startExplain(text: text)
        case .explainImage(let data):
            selection = "camera"
            photo.routeMode(.explain)
            photo.didPickFromLibrary(data)
        }
    }

    /// Shown whenever the device has no network path. A SOLID surface for legibility; it disappears
    /// the moment connectivity returns (which also triggers the auto-retry above).
    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
            Text(Loc.t(
                "Нет соединения — ждём сеть.",
                "No connection — waiting for the network.",
                "Pas de connexion — en attente du réseau.",
                "Sin conexión: esperando la red.",
                "Keine Verbindung – warte auf das Netzwerk.",
                "Nessuna connessione — in attesa della rete."))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    /// Shown when the on-disk store couldn't be opened: the app runs, but nothing saved this session
    /// will survive a relaunch. A SOLID surface (never glass under warning text) for legibility.
    private var degradedStorageBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(Loc.t(
                "Сохранённые данные недоступны. Изменения этой сессии не сохранятся.",
                "Saved data is unavailable. Changes this session won't be kept.",
                "Données enregistrées indisponibles. Les modifications de cette session ne seront pas conservées.",
                "Datos guardados no disponibles. Los cambios de esta sesión no se guardarán.",
                "Gespeicherte Daten nicht verfügbar. Änderungen dieser Sitzung werden nicht gespeichert.",
                "Dati salvati non disponibili. Le modifiche di questa sessione non verranno conservate."))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}
