//
//  OnboardingView.swift
//  EnglishHelper — Presentation
//
//  First-launch welcome. The user picks three languages — interface, studied, native — before the
//  app opens. Deliberately NOT a clone of Settings: a hero glyph + concentric rings + a language-code
//  motif up top, and each choice is a glass card with an icon and a grid of tappable language chips.
//  The interface picker switches the whole screen's language live (RootView re-ids on change), so the
//  app starts in the system language (or English) and follows the user's pick immediately.
//

import SwiftUI
import DesignSystem

public struct OnboardingView: View {
    private let language: LanguageStore
    private let studied: StudiedLanguageStore
    private let target: TargetLanguageStore
    private let onComplete: () -> Void

    @Environment(\.colorScheme) private var scheme

    /// Each language shown by its own name (endonym), so the choice reads the same regardless of the
    /// current interface language.
    private static let endonym: [String: String] = [
        "RU": "Русский", "EN": "English", "FR": "Français",
        "ES": "Español", "DE": "Deutsch", "IT": "Italiano",
    ]

    public init(
        language: LanguageStore,
        studied: StudiedLanguageStore,
        target: TargetLanguageStore,
        onComplete: @escaping () -> Void
    ) {
        self.language = language
        self.studied = studied
        self.target = target
        self.onComplete = onComplete
    }

    public var body: some View {
        @Bindable var language = language
        @Bindable var studied = studied
        @Bindable var target = target
        ZStack {
            ScreenBackground()
            VerticalScrollView {
                VStack(spacing: Tokens.Space.s24) {
                    hero
                    languageCard(
                        icon: "globe",
                        title: Loc.t("Язык интерфейса", "Interface language"),
                        subtitle: Loc.t("Язык, на котором показывается приложение.",
                                        "The language the app is shown in."),
                        options: AppLanguage.allCases,
                        selected: language.language,
                        label: { Self.name(for: $0.abbreviation) },
                        onSelect: { language.language = $0 }
                    )
                    languageCard(
                        icon: "graduationcap.fill",
                        title: Loc.t("Изучаемый язык", "Studied language"),
                        subtitle: Loc.t("Язык, который вы учите. На нём показываются фразы и работает озвучка.",
                                        "The language you're learning. Phrases are shown in it and all speech uses it."),
                        options: StudiedLanguage.allCases,
                        selected: studied.language,
                        label: { Self.name(for: $0.abbreviation) },
                        onSelect: { studied.language = $0 }
                    )
                    languageCard(
                        icon: "house.fill",
                        title: Loc.t("Родной язык", "Native language"),
                        subtitle: Loc.t("Язык переводов и объяснений на экране «Понять».",
                                        "The language of translations and explanations on the Get it screen."),
                        options: TargetLanguage.allCases,
                        selected: target.language,
                        label: { Self.name(for: $0.abbreviation) },
                        onSelect: { target.language = $0 }
                    )
                }
                .padding(Tokens.Space.s20)
            }
        }
        .safeAreaInset(edge: .bottom) {
            EHButton(Loc.t("Начать", "Get started"), icon: "arrow.right",
                     kind: .primary, fillWidth: true, action: onComplete)
                .padding(.horizontal, Tokens.Space.s20)
                .padding(.top, Tokens.Space.s12)
                .padding(.bottom, Tokens.Space.s8)
                .background(
                    LinearGradient(
                        colors: [Tokens.Surface.background.opacity(0), Tokens.Surface.background],
                        startPoint: .top, endPoint: .bottom
                    )
                    .ignoresSafeArea()
                )
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: Tokens.Space.s16) {
            ZStack {
                Circle().strokeBorder(Tokens.Hairline.default, lineWidth: Tokens.Hairline.width)
                    .frame(width: 144, height: 144)
                Circle().strokeBorder(Tokens.Hairline.strong, lineWidth: Tokens.Hairline.width)
                    .frame(width: 110, height: 110)
                Circle().fill(Tokens.Surface.invert).frame(width: 88, height: 88)
                    .shadow(Tokens.Shadow.cardLight, Tokens.Shadow.cardDark, scheme: scheme)
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Tokens.Content.onInvert)
            }
            .padding(.top, Tokens.Space.s24)

            Text(Loc.t("Добро пожаловать", "Welcome"))
                .textStyle(Tokens.Text.title1)
                .foregroundStyle(Tokens.Content.primary)
            Text(Loc.t("Выберите языки, чтобы начать", "Choose your languages to get started"))
                .textStyle(Tokens.Text.subhead)
                .foregroundStyle(Tokens.Content.secondary)
                .multilineTextAlignment(.center)

            // Decorative motif reinforcing the multilingual theme.
            HStack(spacing: Tokens.Space.s8) {
                ForEach(["RU", "EN", "FR", "ES", "DE", "IT"], id: \.self) { code in
                    Text(code)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.3)
                        .padding(.horizontal, Tokens.Space.s8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Tokens.Fill.subtle))
                        .foregroundStyle(Tokens.Content.tertiary)
                }
            }
            .padding(.top, Tokens.Space.s4)
            .accessibilityHidden(true)   // purely decorative — don't read six codes as separate elements
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Language card

    private func languageCard<Option: Hashable>(
        icon: String,
        title: String,
        subtitle: String,
        options: [Option],
        selected: Option,
        label: @escaping (Option) -> String,
        onSelect: @escaping (Option) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s16) {
            HStack(spacing: Tokens.Space.s12) {
                ZStack {
                    Circle().fill(Tokens.Fill.default).frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Tokens.Content.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .textStyle(Tokens.Text.headline)
                        .foregroundStyle(Tokens.Content.primary)
                    Text(subtitle)
                        .textStyle(Tokens.Text.footnote)
                        .foregroundStyle(Tokens.Content.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.s8), count: 3),
                spacing: Tokens.Space.s8
            ) {
                ForEach(options, id: \.self) { option in
                    chip(label(option), selected: option == selected) { onSelect(option) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s20)
        .glassPanel(cornerRadius: Tokens.Radius.card)
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.Space.s12)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .fill(selected ? Tokens.Surface.invert : Tokens.Fill.default)
                )
                .foregroundStyle(selected ? Tokens.Content.onInvert : Tokens.Content.primary)
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Tokens.Motion.quick, value: selected)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private static func name(for abbreviation: String) -> String {
        endonym[abbreviation] ?? abbreviation
    }
}
