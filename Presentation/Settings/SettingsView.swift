//
//  SettingsView.swift
//  EnglishHelper — Presentation
//
//  Settings sheet: live API status, interface + native language, theme, app info.
//  (Phrase tone moved onto the "Сказать"/Say it screen.)
//

import SwiftUI
import StoreKit
import Domain
import DesignSystem

public struct SettingsView: View {
    @State private var model: SettingsViewModel
    @State private var showClearCacheConfirm = false
    @State private var showPaywall = false
    @State private var showManageSubscription = false
    @Environment(SubscriptionState.self) private var subscription
    private let theme: ThemeStore
    private let language: LanguageStore
    private let studied: StudiedLanguageStore
    private let target: TargetLanguageStore
    private let onClose: () -> Void

    public init(
        model: SettingsViewModel,
        theme: ThemeStore,
        language: LanguageStore,
        studied: StudiedLanguageStore,
        target: TargetLanguageStore,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.theme = theme
        self.language = language
        self.studied = studied
        self.target = target
        self.onClose = onClose
    }

    public var body: some View {
        @Bindable var theme = theme
        @Bindable var language = language
        @Bindable var studied = studied
        @Bindable var target = target
        NavigationStack {
            ZStack {
                ScreenBackground()
                VerticalScrollView {
                    VStack(spacing: Tokens.Space.s20) {
                        subscriptionCard
                        connectionCard
                        languageCard(language: $language.language)
                        studiedCard(studied: $studied.language)
                        targetCard(target: $target.language)
                        themeCard(theme: $theme.preference)
                        cacheCard
                        storageCard
                        infoCard
                    }
                    .padding(Tokens.Space.s20)
                }
            }
            .navigationTitle(Loc.t("Настройки", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(Loc.t("Готово", "Done")) { onClose() }
                }
            }
            // Presented from here (not RootView): a second sheet can't stack on the Settings sheet.
            .sheet(isPresented: $showPaywall) {
                PaywallView().environment(subscription)
            }
            .manageSubscriptionsSheet(isPresented: $showManageSubscription)
            .task { await model.check() }
            .task { await model.loadCacheStats() }
            .task { await model.loadStorage() }
        }
    }

    // MARK: Subscription

    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            sectionTitle(Loc.t("Подписка", "Subscription"))
            switch subscription.tier {
            case .unlimited:
                Text(Loc.t("Тестовая сборка: все функции открыты без подписки.",
                           "Test build: every feature is unlocked, no subscription needed."))
                    .textStyle(Tokens.Text.body)
                    .foregroundStyle(Tokens.Content.secondary)
                // App Review runs in the same sandbox as TestFlight (indistinguishable here), so the
                // offer must stay reachable; buying in a test build changes nothing — it's unlocked.
                Divider().overlay(Tokens.Hairline.default)
                subscriptionButton(Loc.t("Посмотреть подписку", "View subscription")) {
                    showPaywall = true
                }
                .accessibilityIdentifier("settings.viewSubscription")
            case .subscribed(let expires):
                infoRow(Loc.t("План", "Plan"), "Gist It Pro")
                if let expires {
                    Divider().overlay(Tokens.Hairline.default)
                    infoRow(Loc.t("Продлится", "Renews"), dateString(expires))
                }
                Divider().overlay(Tokens.Hairline.default)
                subscriptionButton(Loc.t("Управление подпиской", "Manage subscription")) {
                    showManageSubscription = true
                }
                restoreButton
            case .free:
                infoRow(Loc.t("План", "Plan"), Loc.t("Бесплатный", "Free"))
                Text(Loc.t("Перевод — бесплатно. Объяснения и «Сказать» — один запрос в 5 минут, с подпиской без ограничений. Онлайн-перевод — по подписке.",
                           "Translation: free. Explanations and Say it: one request every 5 minutes, unlimited with a subscription. Online translation: with a subscription."))
                    .textStyle(Tokens.Text.footnote)
                    .foregroundStyle(Tokens.Content.tertiary)
                Button { showPaywall = true } label: {
                    Text(Loc.t("Оформить подписку", "Subscribe"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                restoreButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    private var restoreButton: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            subscriptionButton(Loc.t("Восстановить покупки", "Restore purchases")) {
                Task { await subscription.restore() }
            }
            .disabled(subscription.isRestoring)
            if let message = subscription.restoreMessage {
                Text(message)
                    .textStyle(Tokens.Text.footnote)
                    .foregroundStyle(Tokens.Content.tertiary)
            }
        }
    }

    private func subscriptionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .textStyle(Tokens.Text.body)
                .foregroundStyle(Tokens.Content.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func dateString(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: AppLocale.currentCode())))
    }

    // MARK: Connection

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            HStack {
                sectionTitle(Loc.t("Подключение к сервисам", "Service connections"))
                Spacer()
                // One re-check button covers every service (only once none is mid-check).
                if model.translationHealth != .checking, model.explanationHealth != .checking,
                   model.voiceHealth != .checking {
                    Button { Task { await model.check() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.Content.secondary)
                    .accessibilityLabel(Loc.t("Проверить снова", "Check again"))
                }
            }
            // Rows are named by job, not by model id: which concrete model serves a scenario is an
            // implementation detail (and fixed — there is no per-scenario choice any more).
            serviceStatusRow(Loc.t("Модель перевода", "Translation model"), health: model.translationHealth)
            Divider().overlay(Tokens.Hairline.default)
            serviceStatusRow(Loc.t("Модель объяснения", "Explanation model"), health: model.explanationHealth)
            Divider().overlay(Tokens.Hairline.default)
            serviceStatusRow(Loc.t("Голосовая модель", "Voice model"), health: model.voiceHealth)
            Text(Loc.t("Скорость — время ответа на проверочный запрос.",
                       "Speed is how long a test request took to answer."))
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    private func serviceStatusRow(_ name: String, health: SettingsViewModel.Health) -> some View {
        HStack(spacing: Tokens.Space.s12) {
            statusIcon(health)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .textStyle(Tokens.Text.headline)
                    .foregroundStyle(Tokens.Content.primary)
                Text(statusLine(health))
                    .textStyle(Tokens.Text.footnote)
                    .foregroundStyle(Tokens.Content.secondary)
            }
            Spacer()
            if case .ok(let speed) = health {
                speedIndicator(speed)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(name, health: health))
    }

    /// Signal-strength bars (3 / 2 / 1 lit) + a one-word verdict. Monochrome: speed is information,
    /// not an alarm, so it stays out of the system signal colors.
    private func speedIndicator(_ speed: ResponseSpeed) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Image(systemName: "cellularbars", variableValue: barsValue(speed.level))
                .foregroundStyle(Tokens.Content.primary)
            Text(speedWord(speed.level))
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.secondary)
        }
    }

    private func barsValue(_ level: ResponseSpeed.Level) -> Double {
        switch level {
        case .fast: 1.0
        case .medium: 0.6
        case .slow: 0.3
        }
    }

    private func speedWord(_ level: ResponseSpeed.Level) -> String {
        switch level {
        case .fast: Loc.t("Быстро", "Fast")
        case .medium: Loc.t("Средне", "Medium")
        case .slow: Loc.t("Медленно", "Slow")
        }
    }

    @ViewBuilder private func statusIcon(_ health: SettingsViewModel.Health) -> some View {
        switch health {
        case .checking:
            ProgressView().controlSize(.small)
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.Signal.success)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Tokens.Signal.error)
        }
    }

    private func statusLine(_ health: SettingsViewModel.Health) -> String {
        switch health {
        case .checking: Loc.t("Проверяю…", "Checking…")
        case .ok(let speed): Loc.t("Подключено", "Connected") + " · " + seconds(speed)
        case .failed(let reason): reason
        }
    }

    private func seconds(_ speed: ResponseSpeed) -> String {
        let dot = speed.secondsText, comma = dot.replacingOccurrences(of: ".", with: ",")
        return Loc.t("\(comma) с", "\(dot) s", "\(comma) s", "\(comma) s", "\(comma) s", "\(comma) s")
    }

    private func accessibilityText(_ name: String, health: SettingsViewModel.Health) -> String {
        guard case .ok(let speed) = health else { return "\(name): \(statusLine(health))" }
        return "\(name): \(statusLine(health)), \(speedWord(speed.level))"
    }

    // MARK: Interface language

    private func languageCard(language: Binding<AppLanguage>) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            sectionTitle(Loc.t("Язык интерфейса", "Interface language"))
            // SegmentedSelector reads `selected:` as a VALUE (not just a binding), so this view
            // takes a real dependency on the interface language — tapping a segment re-runs the
            // whole sheet's `Loc.t(...)` immediately, switching the interface live.
            SegmentedSelector(
                AppLanguage.allCases,
                selected: language.wrappedValue,
                label: { $0.abbreviation },
                onSelect: { language.wrappedValue = $0 }
            )
            .accessibilityLabel(Loc.t("Язык интерфейса", "Interface language"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    // MARK: Studied language (the language being learned — card headlines + all speech use it)

    private func studiedCard(studied: Binding<StudiedLanguage>) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            sectionTitle(Loc.t("Изучаемый язык", "Studied language"))
            SegmentedSelector(
                StudiedLanguage.allCases,
                selected: studied.wrappedValue,
                label: { $0.abbreviation },
                onSelect: { studied.wrappedValue = $0 }
            )
            .accessibilityLabel(Loc.t("Изучаемый язык", "Studied language"))
            Text(Loc.t("Язык, который вы учите. На нём показываются фразы и работает озвучка.",
                       "The language you're learning. Phrases are shown in it and all speech uses it."))
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    // MARK: Native language (final translations + explanations are produced in this language)

    private func targetCard(target: Binding<TargetLanguage>) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            sectionTitle(Loc.t("Родной язык", "Native language"))
            SegmentedSelector(
                TargetLanguage.allCases,
                selected: target.wrappedValue,
                label: { $0.abbreviation },
                onSelect: { target.wrappedValue = $0 }
            )
            .accessibilityLabel(Loc.t("Родной язык", "Native language"))
            Text(Loc.t("Язык переводов и объяснений на экране «Понять».",
                       "The language of translations and explanations on the Get it screen."))
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    // MARK: Theme

    private func themeCard(theme: Binding<ThemePreference>) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            sectionTitle(Loc.t("Оформление", "Appearance"))
            Picker(Loc.t("Тема", "Theme"), selection: theme) {
                ForEach(ThemePreference.allCases, id: \.self) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.segmented)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    // MARK: Translation cache

    private var cacheCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            sectionTitle(Loc.t("Кэш переводов", "Translation cache"))
            infoRow(Loc.t("В кэше", "Stored"), "\(model.cacheStats.entryCount)")
            Divider().overlay(Tokens.Hairline.default)
            infoRow(Loc.t("Взято из кэша", "Served from cache"), "\(model.cacheStats.hitCount)")
            Divider().overlay(Tokens.Hairline.default)
            Button { showClearCacheConfirm = true } label: {
                Text(Loc.t("Очистить кэш", "Clear cache"))
                    .textStyle(Tokens.Text.body)
                    .foregroundStyle(model.cacheStats.entryCount == 0 ? Tokens.Content.tertiary : Tokens.Signal.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(model.cacheStats.entryCount == 0)
            Text(Loc.t("Повторные переводы одного и того же текста берутся из кэша, а не из модели.",
                       "Repeat translations of the same text are served from the cache, not the model."))
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
        .confirmationDialog(
            Loc.t("Очистить кэш переводов?", "Clear the translation cache?"),
            isPresented: $showClearCacheConfirm, titleVisibility: .visible
        ) {
            Button(Loc.t("Очистить", "Clear"), role: .destructive) { Task { await model.clearCache() } }
            Button(Loc.t("Отмена", "Cancel"), role: .cancel) {}
        }
    }

    // MARK: Disk usage

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            sectionTitle(Loc.t("Место на диске", "Disk usage"))
            infoRow(Loc.t("Кэш переводов", "Translation cache"), byteString(model.storage.cacheBytes))
            Divider().overlay(Tokens.Hairline.default)
            infoRow(Loc.t("История", "History"), byteString(model.storage.historyBytes))
            Divider().overlay(Tokens.Hairline.default)
            infoRow(Loc.t("Аудиозаписи сессий", "Session recordings"), byteString(model.storage.audioBytes))
            Divider().overlay(Tokens.Hairline.default)
            infoRow(Loc.t("Всего", "Total"), byteString(model.storage.totalBytes))
            Text(Loc.t("Тексты — оценка по содержимому записей; аудио — фактический размер файлов.",
                       "Text sizes are estimated from the stored content; audio is the actual file size."))
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    /// Localized byte count ("1,2 МБ") in the APP's interface language — the system formatter alone
    /// would follow the device locale, which the in-app language picker deliberately overrides.
    private func byteString(_ bytes: Int) -> String {
        Int64(bytes).formatted(
            .byteCount(style: .file).locale(Locale(identifier: AppLocale.currentCode()))
        )
    }

    // MARK: Info

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            sectionTitle(Loc.t("О приложении", "About"))
            infoRow(Loc.t("Версия", "Version"), model.appVersion)
            Divider().overlay(Tokens.Hairline.default)
            infoRow(Loc.t("Голос озвучки", "Speech voice"), studied.language.title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).textStyle(Tokens.Text.body).foregroundStyle(Tokens.Content.secondary)
            Spacer()
            Text(value).textStyle(Tokens.Text.body).foregroundStyle(Tokens.Content.primary)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .textStyle(Tokens.Text.caption2)
            .foregroundStyle(Tokens.Content.tertiary)
    }
}
