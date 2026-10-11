//
//  VoiceView.swift
//  EnglishHelper — Presentation
//
//  "Как сказать" screen. Voice OR typed Russian → 3 register-tagged English variants
//  (tap = play, bookmark = save). States: idle / listening / processing / results / error / offline.
//

import SwiftUI
import UIKit    // UIPasteboard.changedNotification (re-arms the Paste affordance on in-app copies)
import Domain
import DesignSystem

public struct VoiceView: View {
    @State private var model: VoiceViewModel
    @FocusState private var fieldFocused: Bool
    /// Dynamic-Type-scaled body line height — the input box matches Get it's "first window" exactly.
    @ScaledMetric(relativeTo: .body) private var bodyLineHeight = Tokens.Text.body.lineHeight
    @Environment(AppUIState.self) private var ui   // for routing per-variant "explain" into Get it
    /// Bumped on every action-button tap — the trigger for its impact haptic (Paste AND submit).
    @State private var actionTapCount = 0
    /// The clipboard can change while the app is backgrounded — re-check on return to foreground.
    @Environment(\.scenePhase) private var scenePhase
    /// `false` for the text-only "Текст" tab (no microphone — same flow, typed input).
    private let showsMic: Bool

    public init(model: VoiceViewModel, showsMic: Bool = true) {
        self.model = model
        self.showsMic = showsMic
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
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
            // Screen title matches the tab name ("Say it" / "Сказать") in every language.
            .navigationTitle(Loc.t("Сказать", "Say it"))
            .settingsTrigger()
            // Leaving the screen (tab switch) drops an input edit the user never submitted, so the
            // field still matches the on-screen results when they come back.
            .onDisappear { model.screenDisappeared() }
            // Keep the Paste affordance honest: re-check the clipboard whenever the screen shows,
            // the app returns to the foreground, or the clipboard changes while active — same
            // contract as the Get-it screen (metadata check only — no iOS paste banner).
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

    /// A background save failure is shown as an alert so it surfaces even while results are on screen
    /// (the inline error UI only renders in the `.failed` phase).
    private var saveErrorBinding: Binding<Bool> {
        Binding(get: { model.saveError != nil }, set: { if !$0 { model.clearSaveError() } })
    }

    // MARK: Input

    private var inputSection: some View {
        VStack(spacing: Tokens.Space.s12) {   // a touch tighter so the empty-state hint clears the tab bar
            // Mode: phrasings of ONE thought ("how to say") vs the useful phrases for a SITUATION
            // ("what to say"). Placed up top so the choice frames the whole interaction.
            SegmentedSelector(
                VoiceViewModel.Mode.allCases,
                selected: model.mode,
                label: { $0.title },
                accessibilityID: "sayit.mode",
                onSelect: { model.selectMode($0) }
            )
            // `.contain` keeps each segment's OWN label (a bare container label would overwrite
            // every segment as "Mode", leaving VoiceOver users unable to tell the options apart).
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Loc.t("Режим", "Mode"))

            // A fixed 4-line box — EXACTLY the Get-it screens' input/first-window height, so the
            // two screens read as one family.
            GlassField(fieldPrompt, text: $model.intent, accessibilityID: "sayit.input",
                       fixedHeight: 4 * bodyLineHeight + 2 * Tokens.Space.s16) {
                fieldFocused = false
                model.pick()
            }
            .focused($fieldFocused)

            // Mic + action side by side in ONE row (half width each) — the compact input block
            // leaves the room below to the results.
            HStack(spacing: Tokens.Space.s12) {
                if showsMic {
                    // Pill-shaped push-to-talk (same form as the action button next to it); the
                    // status caption lives inside the pill.
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
                    // hold), so the hints describe tap-to-start / tap-to-stop, not press-and-hold.
                    .accessibilityHint(model.isListening
                        ? Loc.t("Коснитесь, чтобы остановить и получить варианты", "Tap to stop and get phrasings")
                        : Loc.t("Коснитесь, чтобы начать диктовку на родном языке; сигнал отметит начало записи",
                                "Tap to start dictating in your native language; a tone marks the start"))
                }

                // One slot, two personas: with an EMPTY field and text on the clipboard it is the
                // SYSTEM paste control — its tap IS the pasteboard consent, so iOS never shows the
                // "Allow Paste?" dialog (a programmatic read prompts on every new clipboard).
                // Otherwise it is the mode's action. Every tap gives an impact haptic. Same
                // contract as the Get-it screen.
                Group {
                    if model.showsPasteAction {
                        EHPasteButton { text in
                            fieldFocused = false
                            actionTapCount += 1
                            model.pasteIntoInput(text)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .accessibilityIdentifier("sayit.action")
                    } else {
                        EHButton(actionTitle, icon: actionIcon, kind: .primary, fillWidth: true,
                                 accessibilityID: "sayit.action") {
                            fieldFocused = false
                            actionTapCount += 1
                            model.pick()
                        }
                        .disabled(!actionEnabled)   // EHButton dims itself when disabled
                    }
                }
                .sensoryFeedback(.impact(weight: .medium), trigger: actionTapCount)
            }

            SegmentedSelector(
                ToneOfVoice.allCases,
                selected: model.tone,
                label: { $0.shortTitle },
                accessibilityID: "sayit.tone",
                onSelect: { model.selectTone($0) }
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Loc.t("Тон фраз", "Phrase tone"))
        }
    }

    /// Enabled with something to do (input to submit OR clipboard to paste) and not mid-request/listening.
    private var actionEnabled: Bool {
        model.hasActionAvailable && model.phase != .processing && !model.isListening
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

    // MARK: Mode-aware copy

    /// Field placeholder: a thought to phrase ("how to say") vs a situation to cover ("what to say").
    private var fieldPrompt: String {
        model.mode == .howToSay
            ? Loc.t("Что хотите сказать?", "What do you want to say?",
                    "Que voulez-vous dire ?", "¿Qué quieres decir?",
                    "Was möchtest du sagen?", "Cosa vuoi dire?")
            : Loc.t("Опишите ситуацию", "Describe the situation",
                    "Décrivez la situation", "Describe la situación",
                    "Beschreibe die Situation", "Descrivi la situazione")
    }

    /// With results already shown the button regenerates (`pick()` → `regenerate()`), so the label and
    /// icon must read "another set", not the first-run "find phrasings". (The PASTE persona is the
    /// system control — its label comes from iOS, not from here.)
    private var actionTitle: String {
        if model.phase == .results {
            return Loc.t("Другие варианты", "Other options",
                         "Autres options", "Otras opciones", "Andere Optionen", "Altre opzioni")
        }
        // This button is HALF-width (it shares its row with the mic pill), so every language's
        // longest word must fit one line there (~93 pt on the narrowest iPhone) — long words like
        // "Formulierungen" char-wrap mid-word. Hence "options/tournures", not "formulations".
        return model.mode == .howToSay
            ? Loc.t("Подобрать варианты", "Find phrasings",
                    "Proposer des tournures", "Buscar opciones",
                    "Optionen finden", "Trova opzioni")
            : Loc.t("Подобрать фразы", "Suggest phrases",
                    "Proposer des phrases", "Sugerir frases",
                    "Phrasen finden", "Suggerisci frasi")
    }

    private var actionIcon: String {
        model.phase == .results ? "arrow.triangle.2.circlepath" : "sparkles"
    }

    private var loadingText: String {
        model.mode == .howToSay
            ? Loc.t("Подбираю варианты…", "Finding phrasings…",
                    "Recherche de tournures…", "Buscando opciones…",
                    "Suche Optionen…", "Ricerca opzioni…")
            : Loc.t("Подбираю фразы…", "Finding phrases…",
                    "Recherche de phrases…", "Buscando frases…",
                    "Suche Phrasen…", "Ricerca frasi…")
    }

    private var idleIcon: String {
        model.mode == .howToSay ? "text.bubble" : "bubble.left.and.bubble.right"
    }

    private var idleTitle: String {
        model.mode == .howToSay
            ? Loc.t("Как это сказать?", "How do you say it?",
                    "Comment le dire ?", "¿Cómo se dice?",
                    "Wie sagt man das?", "Come si dice?")
            : Loc.t("Что говорить?", "What should you say?",
                    "Quoi dire ?", "¿Qué decir?",
                    "Was solltest du sagen?", "Cosa dovresti dire?")
    }

    private var idleMessage: String {
        model.mode == .howToSay
            ? Loc.t(
                "Введите или произнесите фразу или мысль — подберу 3 варианта, как это сказать, в выбранном тоне.",
                "Type or say a phrase or thought — I'll offer 3 ways to say it in the chosen tone.",
                "Saisissez ou dites une phrase ou une idée — je proposerai 3 façons de le dire dans le ton choisi.",
                "Escribe o di una frase o idea — te ofreceré 3 formas de decirlo en el tono elegido.",
                "Tippe oder sprich eine Phrase oder einen Gedanken – ich biete 3 Möglichkeiten, es im gewählten Ton zu sagen.",
                "Scrivi o pronuncia una frase o un pensiero: ti offrirò 3 modi per dirlo nel tono scelto.")
            : Loc.t(
                "Опишите ситуацию (например «приём у врача») — подберу самые полезные фразы для неё в выбранном тоне.",
                "Describe a situation (e.g. a doctor's appointment) — I'll suggest the most useful phrases for it in the chosen tone.",
                "Décrivez une situation (par ex. un rendez-vous chez le médecin) — je proposerai les phrases les plus utiles, dans le ton choisi.",
                "Describe una situación (p. ej. una cita con el médico) — sugeriré las frases más útiles, en el tono elegido.",
                "Beschreibe eine Situation (z. B. einen Arzttermin) – ich schlage die nützlichsten Phrasen dafür im gewählten Ton vor.",
                "Descrivi una situazione (ad es. una visita dal medico): ti suggerirò le frasi più utili, nel tono scelto.")
    }

    // MARK: Content (state machine)

    @ViewBuilder private var contentSection: some View {
        switch model.phase {
        case .idle:
            if model.intent.isEmpty {
                StatusView(systemImage: idleIcon, title: idleTitle, message: idleMessage)
                    .padding(.top, Tokens.Space.s8)
            }

        case .listening:
            EmptyView()

        case .processing:
            LoadingView(loadingText)
                .padding(.top, Tokens.Space.s24)

        case .results:
            resultsSection

        case .failed:
            // No extra top padding: StatusView already pads s24 internally, and the failed block is
            // the tallest state (icon + message + Retry) — a second s24 pushed Retry under the tab bar.
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

    private var resultsSection: some View {
        VStack(spacing: Tokens.Space.s16) {
            ForEach(model.variants) { variant in
                PhraseVariantCard(
                    english: variant.en,
                    register: registerLevel(variant.register),
                    contextRU: variant.contextRU,
                    isSaved: model.isSaved(variant),
                    isPlaying: model.isPlaying(variant),
                    onPlay: { model.play(variant) },
                    onToggleSave: { model.toggleSave(variant) },
                    // "Why this one?" → route into the Explain engine for THIS phrasing, contrasted
                    // against the sibling variants. Reuses the same Explain flow as See it / History.
                    onExplain: {
                        let alternatives = model.variants
                            .filter { $0.id != variant.id }
                            .map(\.en)
                        ui.pendingExplain = ExplainRequest(text: variant.en, alternatives: alternatives)
                    }
                )
            }
            // Start over with a fresh thought — the same affordance as Get it's "New phrase" button.
            EHButton(Loc.t("Новая фраза", "New phrase", "Nouvelle phrase", "Nueva frase",
                           "Neue Phrase", "Nuova frase"),
                     icon: "arrow.triangle.2.circlepath", kind: .glass, fillWidth: true) {
                model.reset()
            }
        }
    }

    // MARK: Banners & sheets

    private var apiKeyBanner: some View {
        HStack(spacing: Tokens.Space.s12) {
            Image(systemName: "key.slash")
                .foregroundStyle(Tokens.Signal.warning)
            Text(Loc.t("Нет ключа Claude API — варианты не загрузятся. Добавьте ключ в Secrets.xcconfig.",
                       "No Claude API key — options won't load. Add a key in Secrets.xcconfig."))
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
            Text(Loc.t("Чтобы услышать вас и подобрать фразы, приложению нужен микрофон. Запись не сохраняется.",
                       "To hear you and find phrasings, the app needs the microphone. Nothing is recorded."))
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

    private func registerLevel(_ register: Register) -> RegisterLevel {
        switch register {
        case .formal: .formal
        case .casual, .neutral: .casual   // design styles 3 tiers; neutral → casual
        case .slang: .slang
        }
    }
}
