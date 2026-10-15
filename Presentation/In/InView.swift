//
//  InView.swift
//  EnglishHelper — Presentation
//
//  "In" screen. English voice OR typed text in any language → ONE translation into the configured
//  target language. States: idle / listening / processing / result / error / offline.
//

import SwiftUI
import UIKit    // UIPasteboard.changedNotification (re-arms the Paste affordance on in-app copies)
import Domain
import DesignSystem

public struct InView: View {
    @State private var model: InViewModel
    @FocusState private var fieldFocused: Bool
    /// Dynamic-Type-scaled body line height — the single source of the "first window" height.
    @ScaledMetric(relativeTo: .body) private var bodyLineHeight = Tokens.Text.body.lineHeight
    /// Bumped on every action-button tap — the trigger for its impact haptic (Paste AND Translate).
    @State private var actionTapCount = 0
    /// The clipboard can change while the app is backgrounded — re-check on return to foreground.
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppUIState.self) private var ui
    @Environment(SubscriptionState.self) private var subscription

    public init(model: InViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                if model.mode == .online {
                    // Online mode: the content NEVER scrolls as a whole — panes scroll internally.
                    // It is still wrapped in a ScrollView on purpose: the navigation bar binds its
                    // large-title behavior to the FIRST scroll view it finds, and this one cannot
                    // move (content sized exactly to the container, bounce off) — so the title
                    // stays fully expanded, IDENTICAL to the other screens, while the transcript
                    // panes scroll freely without dragging the header around.
                    GeometryReader { geometry in
                        ScrollView(.vertical) {
                            onlineSection
                                .padding(Tokens.Space.s20)
                                .frame(width: geometry.size.width, height: geometry.size.height,
                                       alignment: .top)
                        }
                        .scrollBounceBehavior(.basedOnSize)   // both axes: sized exactly, never moves
                    }
                } else {
                    VerticalScrollView {
                        VStack(spacing: Tokens.Space.s20) {
                            if model.needsAPIKey { apiKeyBanner }
                            inputSection
                            contentSection
                        }
                        .padding(Tokens.Space.s20)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .navigationTitle(Loc.t("Понять", "Get it"))
            .settingsTrigger()
            // Leaving the screen (tab switch) drops an input edit the user never submitted, so the
            // field still matches the on-screen result when they come back.
            .onDisappear { model.screenDisappeared() }
            // Keep the Paste affordance honest: re-check the clipboard whenever the screen shows,
            // the app returns to the foreground, or the clipboard changes while active — e.g. the
            // Copy button on THIS screen's result card (metadata check only — no iOS paste banner).
            .onAppear { model.refreshClipboardState() }
            // …and poll while visible: another process changing the clipboard in the
            // foreground (Universal Clipboard, a password manager) posts NO notification.
            .task { await model.monitorClipboard() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refreshClipboardState() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
                model.refreshClipboardState()
            }
            .sheet(isPresented: $model.showMicPriming) { primingSheet }
            .alert(Loc.t("Сохранение", "Saving"), isPresented: saveErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.saveError ?? "")
            }
        }
    }

    /// Surface a background save failure regardless of `phase` (inline error UI is only in `.failed`).
    private var saveErrorBinding: Binding<Bool> {
        Binding(get: { model.saveError != nil }, set: { if !$0 { model.clearSaveError() } })
    }

    // MARK: Input

    /// The Get-it "first window" (text-input box in Explain/Translate, Original pane in Online):
    /// ONE exact TOTAL height everywhere — 4 body lines + the pane's s16 padding — so the button
    /// right below it sits at the SAME position on all three screens of the section.
    private var firstWindowContentHeight: CGFloat { 4 * bodyLineHeight }
    private var firstWindowTotalHeight: CGFloat { firstWindowContentHeight + 2 * Tokens.Space.s16 }

    /// Mode at the TOP (mirrors "Say it": the choice frames the interaction). Shared by the text
    /// layout and the Online layout so the selector never jumps between modes.
    private var modeSelector: some View {
        SegmentedSelector(
            InViewModel.Mode.allCases,
            selected: model.mode,
            label: { $0.title },
            accessibilityID: "getit.mode",
            onSelect: { model.selectMode($0) }
        )
        // `.contain` keeps each segment's OWN label (a bare container label would overwrite
        // every segment as "Mode", leaving VoiceOver users unable to tell the options apart).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Loc.t("Режим", "Mode"))
    }

    private var inputSection: some View {
        // s12 spacing MUST match VoiceView's inputSection so the mode selector, field, mic, and caption
        // land at IDENTICAL positions on both screens — no jump when switching Say it ↔ Get it.
        VStack(spacing: Tokens.Space.s12) {
            modeSelector

            // A fixed box of EXACTLY the Online Original pane's height — long text scrolls inside,
            // the box never grows, so the buttons below never move.
            GlassField(Loc.t("Текст на изучаемом языке", "Text in the language you're learning"),
                       text: $model.source, accessibilityID: "getit.input",
                       fixedHeight: firstWindowTotalHeight) {
                fieldFocused = false
                model.submit()
            }
            .focused($fieldFocused)

            // Mic + action side by side in ONE row (half width each) — same compact block as the
            // Say-it screen, so the two screens read as one family.
            HStack(spacing: Tokens.Space.s12) {
                // Pill-shaped push-to-talk (same form as the action button next to it); the status
                // caption lives inside the pill.
                MicButton(status: micStatus, title: micCaption,
                          onPressBegan: {
                              fieldFocused = false
                              model.micPressBegan()
                          },
                          onPressEnded: { model.micPressEnded() },
                          onPressCancelled: { model.micPressCancelled() })
                .accessibilityLabel(Loc.t("Микрофон", "Microphone"))
                .accessibilityValue(model.isListening ? Loc.t("Слушаю", "Listening") : Loc.t("Готов", "Ready"))
                // VoiceOver-only copy: for VoiceOver the control is a TOGGLE (activation can't
                // hold), so the hints describe tap-to-start / tap-to-stop — and the stop hint names
                // what the CURRENT mode will actually run.
                .accessibilityHint(model.isListening
                    ? (model.mode == .translate
                        ? Loc.t("Коснитесь, чтобы остановить и перевести", "Tap to stop and translate")
                        : Loc.t("Коснитесь, чтобы остановить и получить объяснение", "Tap to stop and get an explanation"))
                    : Loc.t("Коснитесь, чтобы начать диктовку на изучаемом языке; сигнал отметит начало записи",
                            "Tap to start dictating in the language you're learning; a tone marks the start"))

                // One slot, two personas: with an EMPTY field and text on the clipboard it is the
                // SYSTEM paste control — its tap IS the pasteboard consent, so iOS never shows the
                // "Allow Paste?" dialog (a programmatic read prompts on every new clipboard).
                // Otherwise it is Translate/Explain. Every tap gives an impact haptic.
                if model.showsPasteAction {
                    EHPasteButton { text in
                        fieldFocused = false
                        actionTapCount += 1
                        model.pasteIntoInput(text)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .accessibilityIdentifier("getit.action")
                } else {
                    EHButton(actionTitle, icon: actionIcon, kind: .primary, fillWidth: true,
                             accessibilityID: "getit.action") {
                        fieldFocused = false
                        actionTapCount += 1
                        model.submit()
                    }
                    .disabled(!actionEnabled)   // EHButton dims itself when disabled
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: actionTapCount)
        }
    }

    // MARK: Online (live translation)

    private var onlineSection: some View {
        VStack(spacing: Tokens.Space.s12) {
            modeSelector
            if model.needsLiveAPIKey { sonioxKeyBanner }
            else if liveNeedsSubscription { liveSubscriptionBanner }
            // The controls sit BETWEEN the two transcript panes (the view's middle slot):
            // Pause (mute/unmute the running session) · Listen (start/stop) · direction switch.
            LiveTranscriptView(text: model.liveText, isStreaming: model.isLiveListening,
                               smallPaneContentHeight: firstWindowContentHeight) {
                // s8 (not s12): four controls share this row — the tighter gap buys the Listen
                // pill the width it needs on the smallest iPhones.
                HStack(spacing: Tokens.Space.s8) {
                    // Pause / Resume: compact glyph — the label is VoiceOver's (and the UI tests').
                    liveSideButton(
                        icon: model.isLivePaused ? "play.fill" : "pause.fill",
                        label: model.isLivePaused
                            ? Loc.t("Дальше", "Resume", "Reprendre", "Seguir", "Weiter", "Riprendi")
                            : Loc.t("Пауза", "Pause", "Pause", "Pausa", "Pause", "Pausa"),
                        action: { model.toggleLivePause() }
                    )
                    .disabled(!model.isLiveListening || model.isLiveStopping)

                    ListenButton(
                        isListening: model.isLiveListening,
                        isStopping: model.isLiveStopping,
                        level: model.liveLevel,
                        idleTitle: Loc.t("Слушать", "Listen", "Écouter", "Escuchar", "Zuhören", "Ascolta"),
                        action: {
                            // Free plan: Listen opens the offer instead (a running session can always stop).
                            if liveNeedsSubscription { ui.showPaywall = true } else { model.toggleLive() }
                        }
                    )
                    .disabled(model.needsLiveAPIKey)

                    // Direction toggle (default studied → native). On a running session it draws a
                    // divider and continues in the opposite direction; idle — just the setting.
                    directionToggle
                }
                if let message = model.liveErrorMessage {
                    Text(message)
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Signal.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// A 50×50 glass glyph flanking the Listen pill (Pause / New). Dims itself when disabled —
    /// `.buttonStyle(.plain)` doesn't (same rationale as EHButton).
    private func liveSideButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        LiveSideButton(icon: icon, label: label, action: action)
    }

    /// The language-direction SWITCH: two positions (left = studied, right = native); the GREEN
    /// highlight marks the language being LISTENED TO — the same live green as the Listen pill —
    /// and slides left↔right on tap. Green on EN = hearing EN, translating into RU; and vice versa.
    private var directionToggle: some View {
        DirectionSwitch(
            leftLabel: StudiedLanguage.current.abbreviation,
            rightLabel: TargetLanguage.current.abbreviation,
            isRightActive: model.isLiveReversed,
            accessibilityTitle: Loc.t("Направление перевода", "Translation direction",
                                      "Sens de traduction", "Dirección de traducción",
                                      "Übersetzungsrichtung", "Direzione di traduzione"),
            accessibilityValue: model.isLiveReversed
                ? "\(TargetLanguage.current.abbreviation)→\(StudiedLanguage.current.abbreviation)"
                : "\(StudiedLanguage.current.abbreviation)→\(TargetLanguage.current.abbreviation)",
            action: { model.toggleLiveDirection() }
        )
        .disabled(model.isLiveStopping)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.isLiveReversed)
    }

    /// Online translation is a subscriber feature (App Store build, free plan). Never blocks stopping.
    private var liveNeedsSubscription: Bool {
        !subscription.tier.canUseLiveTranslation && !model.isLiveListening
    }

    private var liveSubscriptionBanner: some View {
        HStack(spacing: Tokens.Space.s12) {
            Image(systemName: "lock").foregroundStyle(Tokens.Content.secondary)
            Text(Loc.t("Онлайн-перевод доступен по подписке Gist It Pro.",
                       "Online translation is part of Gist It Pro."))
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(Loc.t("Оформить подписку", "Subscribe")) { ui.showPaywall = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(Tokens.Space.s12)
        .glassPanel(cornerRadius: Tokens.Radius.control)
    }

    private var sonioxKeyBanner: some View {
        HStack(spacing: Tokens.Space.s12) {
            Image(systemName: "key.slash").foregroundStyle(Tokens.Signal.warning)
            Text(Loc.t("Нет ключа Soniox API — онлайн-перевод не работает. Добавьте ключ в Secrets.xcconfig.",
                       "No Soniox API key — online translation won't work. Add a key in Secrets.xcconfig."))
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s12)
        .glassPanel(cornerRadius: Tokens.Radius.control)
    }

    /// Enabled with something to do (input to submit OR clipboard to paste) and not mid-request/listening.
    private var actionEnabled: Bool {
        model.hasActionAvailable && model.phase != .processing && !model.isListening
    }

    // (The PASTE persona is the system control — its label/icon come from iOS, not from here.)
    private var actionTitle: String {
        model.mode == .explain ? Loc.t("Объяснить", "Explain") : Loc.t("Перевести", "Translate")
    }

    private var actionIcon: String {
        model.mode == .explain ? "lightbulb" : "character.book.closed"
    }

    // The empty-state hint adapts to the selected mode: Explain describes the nuance breakdown,
    // Translate describes a faithful translation.
    private var idleIcon: String {
        model.mode == .explain ? "lightbulb" : "character.book.closed"
    }

    private var idleTitle: String {
        model.mode == .explain
            ? Loc.t("Что это значит?", "What does it mean?",
                    "Qu'est-ce que ça veut dire ?", "¿Qué significa?",
                    "Was bedeutet das?", "Cosa significa?")
            : Loc.t("Нужен перевод?", "Need a translation?",
                    "Besoin d'une traduction ?", "¿Necesitas una traducción?",
                    "Brauchst du eine Übersetzung?", "Ti serve una traduzione?")
    }

    private var idleMessage: String {
        model.mode == .explain
            ? Loc.t(
                "Введите или надиктуйте фразу — объясню, что она означает в живой языковой среде: смысл и оттенок, насколько формально или резко звучит и с чем это можно сравнить.",
                "Type or dictate a phrase — I'll explain what it really means in real-world use: its sense and nuance, how formal or blunt it sounds, and what it compares to.",
                "Saisissez ou dictez une phrase — j'expliquerai ce qu'elle veut vraiment dire dans la langue vivante : son sens et sa nuance, son registre (formel ou direct) et à quoi la comparer.",
                "Escribe o dicta una frase — te explicaré qué significa de verdad en el uso real del idioma: su sentido y matiz, qué tan formal o brusca suena y con qué se puede comparar.",
                "Tippe oder diktiere eine Phrase – ich erkläre, was sie im echten Sprachgebrauch wirklich bedeutet: Sinn und Nuance, wie förmlich oder direkt sie klingt und womit sie vergleichbar ist.",
                "Scrivi o detta una frase: ti spiegherò cosa significa davvero nell'uso reale della lingua: senso e sfumatura, quanto suona formale o diretta e a cosa si può paragonare.")
            : Loc.t(
                "Введите или надиктуйте фразу — дам точный перевод по смыслу на изучаемый и родной язык.",
                "Type or dictate a phrase — I'll give a faithful translation in the language you're learning and your own.",
                "Saisissez ou dictez une phrase — j'en donnerai une traduction fidèle dans la langue que vous apprenez et dans la vôtre.",
                "Escribe o dicta una frase — daré una traducción fiel en el idioma que estás aprendiendo y en el tuyo.",
                "Tippe oder diktiere eine Phrase – ich gebe eine getreue Übersetzung in der Sprache, die du lernst, und in deiner eigenen.",
                "Scrivi o detta una frase: fornirò una traduzione fedele nella lingua che stai imparando e nella tua.")
    }

    private var micCaption: String {
        // Short captions: the pill shares its row with the action button (half width each).
        switch model.micStatus {
        case .listening: Loc.t("Слушаю…", "Listening…")
        case .processing: Loc.t("Минуту…", "One moment…")
        // "Зажмите", not "Удерживайте": the longest word must fit the HALF-width pill's line on the
        // narrowest iPhone (~93 pt of text width), or the caption char-wraps mid-word ("Удерживайт-е").
        case .idle: Loc.t("Зажмите и говорите", "Hold and speak")
        }
    }

    // MARK: Content (state machine)

    @ViewBuilder private var contentSection: some View {
        switch model.phase {
        case .idle:
            if model.source.isEmpty {
                StatusView(systemImage: idleIcon, title: idleTitle, message: idleMessage)
                    .padding(.top, Tokens.Space.s24)
            }

        case .listening:
            EmptyView()

        case .processing:
            LoadingView(model.mode == .explain ? Loc.t("Объясняю…", "Explaining…") : Loc.t("Перевожу…", "Translating…"))
                .padding(.top, Tokens.Space.s24)

        case .result:
            resultSection

        case .failed:
            // No extra top padding: StatusView pads s24 internally; a second s24 pushed Retry under
            // the tab bar in the tallest (error + Retry) state. See VoiceView for the same fix.
            if model.needsSubscription {
                StatusView(
                    systemImage: "lock",
                    title: Loc.t("Лимит бесплатного плана", "Free plan limit"),
                    message: model.errorMessage,
                    actionTitle: Loc.t("Оформить подписку", "Subscribe"),
                    action: { ui.showPaywall = true }
                )
            } else {
                StatusView(
                    systemImage: model.isOffline ? "wifi.slash" : "exclamationmark.triangle",
                    title: model.isOffline ? Loc.t("Нет соединения", "No connection") : Loc.t("Не получилось", "Something went wrong"),
                    message: model.errorMessage,
                    actionTitle: model.canSubmit ? Loc.t("Повторить", "Retry") : nil,
                    action: model.canSubmit ? { model.submit() } : nil
                )
            }
        }
    }

    @ViewBuilder private var resultSection: some View {
        VStack(spacing: Tokens.Space.s16) {
            if let explanation = model.explanation {
                explanationCard(explanation)
            } else if !model.translations.isEmpty {
                translationCard(model.translations)
            }
            EHButton(Loc.t("Новое выражение", "New phrase"),
                     icon: "arrow.triangle.2.circlepath", kind: .glass, fillWidth: true) {
                model.reset()
            }
        }
    }

    /// Translate mode: the studied-language rendering is the headline (play + bookmark + the saved
    /// study item); below it sit the translation(s) — each in the main colour with a dimmed context
    /// note (a single line for an unambiguous word or a phrase; several when a word has distinct senses).
    private func translationCard(_ variants: [TranslationVariant]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            // Mode tag (left) + action icons (right) on their own row above the source text, so the
            // source text below keeps the FULL card width — same layout as the generation cards.
            HStack(spacing: Tokens.Space.s16) {
                CardTagView(Loc.t("Перевод", "Translation", "Traduction", "Traducción", "Übersetzung", "Traduzione"))
                Spacer(minLength: Tokens.Space.s8)
                if !model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { model.play() } label: {
                        Image(systemName: model.isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                            .symbolEffect(.variableColor.iterative, isActive: model.isPlaying)
                            .foregroundStyle(model.isPlaying ? Tokens.Content.primary : Tokens.Content.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Loc.t("Озвучить", "Play"))

                    Button { model.startExplain(text: model.sourceText) } label: {
                        Image(systemName: "lightbulb")
                            .font(.system(size: Tokens.Icon.cardAction, weight: .medium))
                            .foregroundStyle(Tokens.Content.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Loc.t("Объяснить", "Explain"))

                    CopyButton(model.sourceText, style: .icon,
                               accessibilityLabel: Loc.t("Скопировать выражение", "Copy expression"))
                    ShareButton(model.sourceText, style: .icon,
                                accessibilityLabel: Loc.t("Поделиться выражением", "Share expression"))
                }
                Button { model.toggleSave() } label: {
                    Image(systemName: model.isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: Tokens.Icon.cardActionProminent, weight: .medium))
                        .foregroundStyle(model.isSaved ? Tokens.Content.primary : Tokens.Content.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isSaved
                    ? Loc.t("Убрать из изучаемого", "Remove from study list")
                    : Loc.t("Сохранить в изучаемое", "Save to study list"))
            }

            Text(model.sourceText)
                .textStyle(Tokens.Text.headline)
                .foregroundStyle(Tokens.Content.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(Tokens.Hairline.default).frame(height: Tokens.Hairline.width)

            // Each translation in the main colour, with a dimmed context note below saying which sense
            // it fits. A single translation (unambiguous word / phrase) shows no context note. Each
            // translation is individually copyable; a hairline separates multiple senses.
            VStack(alignment: .leading, spacing: Tokens.Space.s16) {
                ForEach(Array(variants.enumerated()), id: \.offset) { index, variant in
                    VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                        HStack(alignment: .top, spacing: Tokens.Space.s8) {
                            Text(variant.text)
                                .textStyle(Tokens.Text.body)
                                .foregroundStyle(Tokens.Content.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Tokens.Space.s8)
                            CopyButton(variant.text, style: .icon,
                                       accessibilityLabel: Loc.t("Скопировать перевод", "Copy translation"))
                            ShareButton(variant.text, style: .icon,
                                        accessibilityLabel: Loc.t("Поделиться переводом", "Share translation"))
                        }
                        if !variant.context.isEmpty {
                            Text(variant.context)
                                .textStyle(Tokens.Text.footnote)
                                .foregroundStyle(Tokens.Content.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if index < variants.count - 1 {
                        Rectangle().fill(Tokens.Hairline.default).frame(height: Tokens.Hairline.width)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s16)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    /// Explain mode: the studied-language rendering is the headline (the study item — bookmark + play
    /// attach to it), with the nuance broken out below in the native language. Shared card.
    private func explanationCard(_ explanation: ExpressionExplanation) -> some View {
        ExplanationCardView(
            studied: model.sourceText,
            explanation: explanation,
            isPlaying: model.isPlaying,
            onPlay: { model.play() },
            isSaved: model.isSaved,
            onToggleSave: { model.toggleSave() }
        )
    }

    // MARK: Banners & sheets

    private var apiKeyBanner: some View {
        HStack(spacing: Tokens.Space.s12) {
            Image(systemName: "key.slash")
                .foregroundStyle(Tokens.Signal.warning)
            Text(Loc.t("Нет ключа Claude API — перевод не загрузится. Добавьте ключ в Secrets.xcconfig.",
                       "No Claude API key — translation won't load. Add a key in Secrets.xcconfig."))
                .textStyle(Tokens.Text.footnote)
                .foregroundStyle(Tokens.Content.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s12)
        .glassPanel(cornerRadius: Tokens.Radius.control)
    }

    private var primingSheet: some View {
        VStack(spacing: Tokens.Space.s16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 44))
                .foregroundStyle(Tokens.Content.primary)
                .padding(.top, Tokens.Space.s32)
            Text(Loc.t("Доступ к микрофону", "Microphone access"))
                .textStyle(Tokens.Text.title2)
                .foregroundStyle(Tokens.Content.primary)
            // Honest about Online mode: unlike push-to-talk dictation, live sessions ARE recorded
            // (that's their replay feature) — the priming copy must never claim otherwise.
            Text(Loc.t(
                "Чтобы услышать и перевести речь, приложению нужен микрофон. Диктовка не сохраняется; онлайн-сессии записываются и остаются в Истории.",
                "To hear and translate speech, the app needs the microphone. Dictation isn't stored; online sessions are recorded and kept in History."))
                .textStyle(Tokens.Text.body)
                .foregroundStyle(Tokens.Content.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Tokens.Space.s24)
            Spacer()
            VStack(spacing: Tokens.Space.s8) {
                EHButton(Loc.t("Разрешить", "Allow"), kind: .primary, fillWidth: true) { model.confirmPriming() }
                EHButton(Loc.t("Не сейчас", "Not now"), kind: .ghost, fillWidth: true) { model.cancelPriming() }
            }
            .padding(.horizontal, Tokens.Space.s20)
            .padding(.bottom, Tokens.Space.s24)
        }
        .frame(maxWidth: .infinity)
        .background(Tokens.Surface.background)
        .presentationDetents([.medium])
    }

    // MARK: Mapping

    private var micStatus: MicButton.Status {
        switch model.micStatus {
        case .idle: .idle
        case .listening: .listening
        case .processing: .processing
        }
    }
}

/// Compact glass glyph button (Pause / New) flanking the Listen pill in Online mode. Fixed 50×50:
/// it must never compete with the pill for width, whatever the label localizes to.
private struct LiveSideButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Tokens.Content.primary)
                .frame(width: 50, height: 50)
                .glassPanel(cornerRadius: Tokens.Radius.pill)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

/// Two-position language switch for Online mode. The LIVE-GREEN capsule marks the language the
/// microphone listens to and SLIDES between the positions on tap (whole control = one button;
/// VoiceOver reads the full direction, e.g. "EN→RU").
private struct DirectionSwitch: View {
    let leftLabel: String
    let rightLabel: String
    let isRightActive: Bool
    let accessibilityTitle: String
    let accessibilityValue: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Namespace private var knob

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                segment(leftLabel, active: !isRightActive)
                segment(rightLabel, active: isRightActive)
            }
            .padding(4)
            .frame(height: 50)
            .glassPanel(cornerRadius: Tokens.Radius.pill)
            .animation(Tokens.Motion.quick, value: isRightActive)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilityValue)
    }

    private func segment(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(active ? Tokens.Content.onSignal : Tokens.Content.secondary)
            .frame(width: 60, height: 42)
            .background {
                if active {
                    Capsule()
                        .fill(Tokens.Signal.live)
                        .matchedGeometryEffect(id: "active", in: knob)
                }
            }
    }
}
