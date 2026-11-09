//
//  Tokens.swift
//  EnglishHelper — DesignSystem
//
//  SINGLE SOURCE OF TRUTH for the EnglishHelper visual language.
//
//  Provenance: extracted ONCE (Prompt 0) from the design handoff bundle at
//  `design_system/englishhelper/project/`. The canonical values live in `theme.css`
//  (the CSS custom properties the design HTML imports); scales (type / spacing / radii /
//  motion / register / icon) come from `foundations.jsx` and `kit-core.jsx`.
//  After this extraction the HTML/CSS bundle is ARCHIVED — these tokens are authoritative.
//
//  Design language: monochrome, iOS 26 "Liquid Glass". Pure black / white-gray hierarchy,
//  glass capsules, thin-line iconography. System (red/green/amber/blue) colors are
//  FUNCTIONAL SIGNALS only — never decorative.
//
//  Rules for everyone downstream:
//   • Components and screens reference THESE tokens, never raw hex / pt values.
//   • Do NOT rename, reinterpret, or add raw values here without going back to the design.
//   • Items marked `⚠️ FLAG` are referenced by the design but lack an explicit value,
//     or are named in the brief but not realized in the artifact — they are NOT guessed.
//
//  Source line references use `file:line` from the bundle (e.g. `theme.css:23`).
//

import SwiftUI
import UIKit

// MARK: - Color construction helpers

public extension Color {
    /// sRGB color from a 0xRRGGBB literal, with optional opacity.
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// A dynamic color that resolves light/dark at render time from the trait collection.
    /// This is how every light+dark token below stays a single value the views can use.
    init(light: Color, dark: Color) {
        self = Color(UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

// MARK: - Tokens namespace

public enum Tokens {

    // MARK: Surfaces
    //  Backgrounds and card fills. In DARK the surfaces are translucent white OVERLAYS
    //  (so the glass/blur reads through), not opaque panels — see notes.
    public enum Surface {
        /// App base background. `--bg`  ·  theme.css:21 (dark) / theme.css:56 (light)
        public static let background = Color(light: Color(hex: 0xF2F2F7), dark: .black)
        /// Raised / grouped background. `--bg-2`  ·  theme.css:22 / theme.css:57
        public static let backgroundRaised = Color(light: .white, dark: Color(hex: 0x0B0B0C))
        /// Primary card surface. `--surface`  ·  theme.css:23 / theme.css:58
        /// ⚠️ DARK value is a 5.5% translucent white overlay (rgba(255,255,255,0.055)),
        /// NOT opaque white — foundations.jsx:44 labels it "wht 5.5%".
        public static let primary = Color(light: .white, dark: .white.opacity(0.055))
        /// Second-level surface. `--surface-2`  ·  theme.css:24 / theme.css:59
        /// Also the `casual` register-tag fill (kit-core.jsx:106).
        public static let secondary = Color(light: .white, dark: .white.opacity(0.10))
        /// Third-level surface. `--surface-3`  ·  theme.css:25 / theme.css:60
        public static let tertiary = Color(light: Color(hex: 0xF7F7FA), dark: .white.opacity(0.14))
        /// Inverted surface = primary button / active chip / active segment fill.
        /// `--invert`  ·  theme.css:39 / theme.css:74  (same value as `Content.primary`, kept distinct semantically)
        public static let invert = Color(light: Color(hex: 0x060607), dark: .white)
    }

    // MARK: Content (text + icon foreground)
    //  Dark values are true iOS label grays (rgba(235,235,245,·)); light values are
    //  iOS label grays (rgba(60,60,67,·)). NOT plain opacity of the text color.
    public enum Content {
        /// Primary text / icon. `--text`  ·  theme.css:32 / theme.css:67
        public static let primary = Color(light: Color(hex: 0x060607), dark: .white)
        /// Secondary text (62%). `--text-2`  ·  theme.css:33 / theme.css:68
        public static let secondary = Color(light: Color(hex: 0x3C3C43, opacity: 0.62),
                                            dark: Color(hex: 0xEBEBF5, opacity: 0.62))
        /// Tertiary text (34%). `--text-3`  ·  theme.css:34 / theme.css:69
        public static let tertiary = Color(light: Color(hex: 0x3C3C43, opacity: 0.34),
                                           dark: Color(hex: 0xEBEBF5, opacity: 0.34))
        /// Quaternary / faintest (20%); chevrons, sheet grabber. `--text-4`  ·  theme.css:35 / theme.css:70
        public static let quaternary = Color(light: Color(hex: 0x3C3C43, opacity: 0.20),
                                             dark: Color(hex: 0xEBEBF5, opacity: 0.20))
        /// Text / icon on inverted surfaces (primary buttons). `--on-invert`  ·  theme.css:38 / theme.css:73
        public static let onInvert = Color(light: .white, dark: .black)
        /// White text/icon on a functional-signal fill (delete, learned check) or on the
        /// solid scrim / camera chrome. Theme-independent — those contexts are always dark.
        ///  ·  kit-parts.jsx:166,186 · kit-parts.jsx:257 · screens.jsx:208
        public static let onSignal = Color.white
    }

    // MARK: Hairlines (separators / thin borders)
    public enum Hairline {
        /// Default separator. `--hairline`  ·  theme.css:30 / theme.css:65
        public static let `default` = Color(light: Color(hex: 0x3C3C43, opacity: 0.14),
                                            dark: .white.opacity(0.10))
        /// Stronger hairline (register-tag borders, dividers). `--hairline-strong`  ·  theme.css:31 / theme.css:66
        public static let strong = Color(light: Color(hex: 0x3C3C43, opacity: 0.24),
                                         dark: .white.opacity(0.18))
        /// Standard hairline stroke width used throughout the kit (0.5pt). e.g. kit-core.jsx:72,91,127
        public static let width: CGFloat = 0.5
    }

    // MARK: Fills (tonal button / track backgrounds)
    public enum Fill {
        /// Tonal fill (segmented track, tonal button). `--fill`  ·  theme.css:36 / theme.css:71
        public static let `default` = Color(light: Color(hex: 0x0A0A0C, opacity: 0.055),
                                            dark: .white.opacity(0.12))
        /// Fainter fill. `--fill-2`  ·  theme.css:37 / theme.css:72
        public static let subtle = Color(light: Color(hex: 0x0A0A0C, opacity: 0.035),
                                         dark: .white.opacity(0.07))
    }

    // MARK: Functional signals (FUNCTIONAL ONLY — never decorative)
    public enum Signal {
        /// Success / "learned". `--green`  ·  theme.css:46 / theme.css:80
        public static let success = Color(light: Color(hex: 0x28BD4E), dark: Color(hex: 0x30D158))
        /// Error / destructive. `--red`  ·  theme.css:47 / theme.css:81
        public static let error = Color(light: Color(hex: 0xFF3B30), dark: Color(hex: 0xFF453A))
        /// Warning. `--amber`  ·  theme.css:48 / theme.css:82
        public static let warning = Color(light: Color(hex: 0xE8930C), dark: Color(hex: 0xFFD60A))
        /// System link (iOS blue). `--blue`  ·  theme.css:49 / theme.css:83
        public static let link = Color(light: Color(hex: 0x007AFF), dark: Color(hex: 0x0A84FF))
        /// The single voice-live hue ("listening"). `--live` (== success).  ·  theme.css:50 / theme.css:84
        /// Note: the design expresses voice STATE through MOTION, not color — this hue is a tint accent only.
        public static let live = Color(light: Color(hex: 0x28BD4E), dark: Color(hex: 0x30D158))
    }

    // MARK: Materials — Liquid Glass
    //  Floating bars and controls. Prefer the SYSTEM material (auto light/dark, real blur)
    //  with a `Glass.border` hairline overlay; the explicit tint colors below are the
    //  design's literal fallback values (rgba) for when a flat tint is needed.
    public enum Material {
        /// Glass for floating bars / controls. `--glass`. Map → `.regularMaterial`.
        ///  ·  theme.css:26 / theme.css:61  (blur ~18–20px saturate 1.4 in the prototype)
        public static let glass: SwiftUI.Material = .regularMaterial
        /// Stronger glass (tab bar). `--glass-strong`. Map → `.thickMaterial`.  ·  theme.css:27 / theme.css:62
        public static let glassStrong: SwiftUI.Material = .thickMaterial
        /// ⚠️ FLAG: thin-overlay tier. The brief asks to tie thin overlays to `.ultraThinMaterial`,
        /// but NO explicit token value exists in the artifact. Reserved mapping only — not an extracted value.
        public static let thin: SwiftUI.Material = .ultraThinMaterial
    }

    // MARK: Chart — data marks (Study dashboard)
    //  Validated with the dataviz validator against the card surface in each mode — light #FAFAFC,
    //  dark #141415; dark is its own set, not a flip. Stages: not yet learned (new, learning, young) in
    //  grey — an ordinal ramp: monotone lightness, ΔL ≥ 0.06, faint end ≥ 2:1 — and LEARNED (mature: an
    //  interval of 21+ days) in green, told apart from the grey next to it (CVD ΔE ≥ 12.7, normal ΔE ≥
    //  18.4 light / 21.7 dark; ≥ 3:1 on the surface). The legend's labels and counts carry every stage.
    public enum Chart {
        /// Ordered stages (flashcards: new → learning → young → mature); the last one is "learned".
        public static let stage = [
            Color(light: Color(hex: 0xAEAEB4), dark: Color(hex: 0x5A5A5F)),
            Color(light: Color(hex: 0x86868C), dark: Color(hex: 0x86868C)),
            Color(light: Color(hex: 0x5A5A60), dark: Color(hex: 0xB4B4BA)),
            Color(light: Color(hex: 0x1E8E43), dark: Color(hex: 0x28A84E)),
        ]
        /// A single-series bar (grey); `barEmphasis` marks the one that matters (today).
        public static let bar = Color(light: Color(hex: 0x86868C), dark: Color(hex: 0x86868C))
        public static let barEmphasis = Color(light: Color(hex: 0x1C1C1E), dark: Color(hex: 0xF2F2F7))
        /// Progress lines (`ProgressLine`): done in the learned green; sent and waiting for an answer in grey
        /// (validated against the green: CVD ΔE 9.1 light / 13.7 dark, normal ΔE 16.3 / 20.3, ≥ 3:1).
        public static let progressDone = stage[3]
        public static let progressPending = Color(light: Color(hex: 0x86868C), dark: Color(hex: 0x6E6E73))
        public static let progressTrack = Color(light: Color(hex: 0x787880, opacity: 0.16),
                                                dark: Color(hex: 0x787880, opacity: 0.32))
        /// Gap between adjacent fills (stacked segments, neighbouring bars).
        public static let gap: CGFloat = 2
        /// Rounding of a bar's data end.
        public static let barRadius: CGFloat = 4
    }

    /// Literal glass tint values + border/highlight (for flat-tint fallback or material overlays).
    public enum Glass {
        /// `--glass` tint  ·  theme.css:26 / theme.css:61
        public static let tint = Color(light: .white.opacity(0.58), dark: Color(hex: 0x1E1E20, opacity: 0.50))
        /// `--glass-strong` tint  ·  theme.css:27 / theme.css:62
        public static let tintStrong = Color(light: .white.opacity(0.80), dark: Color(hex: 0x141416, opacity: 0.66))
        /// Glass edge hairline. `--glass-border`  ·  theme.css:28 / theme.css:63
        /// (Light bumped from 0.06 → a defined gray: cards were nearly invisible on the light bg.)
        public static let border = Color(light: Color(hex: 0x3C3C43, opacity: 0.22), dark: .white.opacity(0.14))
        /// Top inner highlight. `--glass-hi`  ·  theme.css:29 / theme.css:64
        public static let highlight = Color(light: .white.opacity(0.70), dark: .white.opacity(0.10))
        /// Backdrop blur radius used by glass controls (prototype: 18–24px).  ·  kit-core.jsx:73,162
        /// Only meaningful if rendering a manual blur instead of a system `Material`.
        public static let blur: CGFloat = 20
    }

    // MARK: Scrim — SOLID (text over photo / camera)
    //  ⚠️ The scrim is OPAQUE, NOT a blurred material. Text over a photo/camera frame sits
    //  ONLY on the scrim. (The brief's "scrim.blur" name has no value in the artifact — the
    //  blurred backdrop is `Material.glass`, not a scrim. See FLAGS.)
    public enum Scrim {
        /// Solid scrim color. `--scrim`  ·  theme.css:41 / theme.css:76
        public static let solid = Color(light: Color(hex: 0x121214, opacity: 0.84),
                                        dark: Color(hex: 0x08080A, opacity: 0.84))
        /// Top→bottom gradient scrim (transparent → near-solid). `--scrim-grad`  ·  theme.css:42 / theme.css:77
        public static let gradient = LinearGradient(
            stops: [
                .init(color: Color(light: Color(hex: 0x121214, opacity: 0.00),
                                   dark: Color(hex: 0x08080A, opacity: 0.00)), location: 0.00),
                .init(color: Color(light: Color(hex: 0x121214, opacity: 0.84),
                                   dark: Color(hex: 0x08080A, opacity: 0.86)), location: 0.58),
                .init(color: Color(light: Color(hex: 0x121214, opacity: 0.95),
                                   dark: Color(hex: 0x08080A, opacity: 0.96)), location: 1.00),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: Shadows
    //  CSS blur radius is mapped to SwiftUI shadow radius as blur/2 (closest visual match).
    //  ⚠️ The dark `card` shadow also carries a 1px inset white highlight (theme.css:44) that a
    //  drop shadow can't express — apply as a top inner stroke on the card if needed.
    public struct ShadowToken: Sendable {
        public let color: Color
        public let radius: CGFloat
        public let x: CGFloat
        public let y: CGFloat
    }
    public enum Shadow {
        /// Floating elements. `--shadow`  ·  theme.css:43 (dark) / theme.css:78 (light)
        public static let floatingLight = ShadowToken(color: Color(hex: 0x141428, opacity: 0.14), radius: 18, x: 0, y: 10)
        public static let floatingDark  = ShadowToken(color: .black.opacity(0.55), radius: 22, x: 0, y: 10)
        /// Cards. `--shadow-card` (drop layer)  ·  theme.css:44 (dark) / theme.css:79 (light)
        public static let cardLight = ShadowToken(color: Color(hex: 0x141428, opacity: 0.10), radius: 20, x: 0, y: 14)
        public static let cardDark  = ShadowToken(color: .black.opacity(0.50), radius: 25, x: 0, y: 18)
    }

    // MARK: Typography — SF Pro (system), tabular numerals
    //  Canonical scale from theme.css `.t-*` classes. `lineHeight`/`tracking` are in points.
    //  ⚠️ Large Title tracking is -0.5 here (theme.css:89); foundations.jsx:83 & kit-core.jsx:55
    //     use -0.6 in live headers. Canonical token = theme.css value (-0.5).
    //  ⚠️ Title 2 weight is 650 — no exact system weight exists; rounded to `.semibold`.
    public struct TextStyleToken: Sendable {
        public let size: CGFloat
        public let lineHeight: CGFloat
        public let weight: Font.Weight
        /// The source CSS weight (400–700) — kept for fidelity; `weight` is the nearest system mapping.
        public let weightCSS: Int
        public let tracking: CGFloat

        /// Scales the design point size with Dynamic Type (via `UIFontMetrics`) so the whole app
        /// responds to the user's Larger Text setting — `.system(size:)` alone is frozen. SwiftUI
        /// re-evaluates this on content-size-category changes, so it tracks live.
        public var font: Font {
            Font(UIFontMetrics.default.scaledFont(for: UIFont.systemFont(ofSize: size, weight: weight.uiKit)))
        }
        /// Extra leading to approximate the design line-height, scaled to match the scaled font so the
        /// spacing stays proportional at larger Dynamic Type sizes.
        public var lineSpacing: CGFloat {
            let scaledTarget = UIFontMetrics.default.scaledValue(for: lineHeight)
            let scaledFontLineHeight = UIFontMetrics.default
                .scaledFont(for: UIFont.systemFont(ofSize: size, weight: weight.uiKit)).lineHeight
            return max(0, scaledTarget - scaledFontLineHeight)
        }
    }
    //  ⚠️ PRODUCT OVERRIDE: every size + lineHeight below is the design scale MINUS 1pt (a global
    //     "one notch smaller" type request). The leading `size / lineHeight` annotation is the
    //     adjusted value; `theme.css:NN` still points at the original design source (+1pt).
    /// The back of a flashcard: the answer as large as the prompt (`Text.title1`), the example and the
    /// notes scaled up with it (×1.25 of `body` / `subhead`). Synonyms and notes share one style.
    public enum Flashcard {
        /// The front: the phrase (or its meaning) being asked.
        public static let prompt = Text.title1
        /// The answer — the same size as the prompt, one weight lighter. 25 / 30 / 600
        public static let answer = TextStyleToken(size: 25, lineHeight: 30, weight: .semibold, weightCSS: 600, tracking: -0.4)
        /// The example sentence (×1.25 of `body`). 20 / 27 / 400
        public static let example = TextStyleToken(size: 20, lineHeight: 27, weight: .regular, weightCSS: 400, tracking: 0)
        /// Synonyms and the context note (×1.25 of `subhead`). 17.5 / 24 / 400
        public static let note = TextStyleToken(size: 17.5, lineHeight: 24, weight: .regular, weightCSS: 400, tracking: 0)
    }

    public enum Text {
        /// 31 / 37 / 700 / -0.5  ·  theme.css:89  (design 32/38 −1)
        public static let largeTitle = TextStyleToken(size: 31, lineHeight: 37, weight: .bold,     weightCSS: 700, tracking: -0.5)
        /// 25 / 30 / 700 / -0.4  ·  theme.css:90  (design 26/31 −1)
        public static let title1     = TextStyleToken(size: 25, lineHeight: 30, weight: .bold,     weightCSS: 700, tracking: -0.4)
        /// 20 / 25 / 650 / -0.3  ·  theme.css:91  (design 21/26 −1; 650 → .semibold, see FLAG)
        public static let title2     = TextStyleToken(size: 20, lineHeight: 25, weight: .semibold, weightCSS: 650, tracking: -0.3)
        /// 18 / 23 / 600 / -0.2  ·  theme.css:92  (design 19/24 −1)
        public static let title3     = TextStyleToken(size: 18, lineHeight: 23, weight: .semibold, weightCSS: 600, tracking: -0.2)
        /// 16 / 21 / 600 / -0.1  ·  theme.css:93  (design 17/22 −1)
        public static let headline   = TextStyleToken(size: 16, lineHeight: 21, weight: .semibold, weightCSS: 600, tracking: -0.1)
        /// 16 / 22 / 400 / 0  ·  theme.css:94  (design 17/23 −1)
        public static let body       = TextStyleToken(size: 16, lineHeight: 22, weight: .regular,  weightCSS: 400, tracking: 0)
        /// 15 / 20 / 400 / 0  ·  theme.css:95  (design 16/21 −1)
        public static let callout    = TextStyleToken(size: 15, lineHeight: 20, weight: .regular,  weightCSS: 400, tracking: 0)
        /// 14 / 19 / 400 / 0  ·  theme.css:96  (design 15/20 −1)
        public static let subhead    = TextStyleToken(size: 14, lineHeight: 19, weight: .regular,  weightCSS: 400, tracking: 0)
        /// 12 / 16 / 400 / 0  ·  theme.css:97  (design 13/17 −1)
        public static let footnote   = TextStyleToken(size: 12, lineHeight: 16, weight: .regular,  weightCSS: 400, tracking: 0)
        /// 11 / 14 / 500 / 0  ·  theme.css:98  (design 12/15 −1)
        public static let caption    = TextStyleToken(size: 11, lineHeight: 14, weight: .medium,   weightCSS: 500, tracking: 0)
        /// 10 / 12 / 600 / 0.3 (UPPERCASE in use)  ·  theme.css:99  (design 11/13 −1)
        public static let caption2   = TextStyleToken(size: 10, lineHeight: 12, weight: .semibold, weightCSS: 600, tracking: 0.3)
    }

    // MARK: Spacing — 4 / 8 pt grid (foundations.jsx:112)
    public enum Space {
        /// Base grid unit.
        public static let grid: CGFloat = 4
        public static let s4:  CGFloat = 4
        public static let s8:  CGFloat = 8
        public static let s12: CGFloat = 12
        public static let s16: CGFloat = 16
        public static let s20: CGFloat = 20
        public static let s24: CGFloat = 24
        public static let s32: CGFloat = 32
        public static let s40: CGFloat = 40
        /// The full scale, in order.
        public static let scale: [CGFloat] = [4, 8, 12, 16, 20, 24, 32, 40]
    }

    // MARK: Corner radii (kit-core.jsx:4 · foundations.jsx:130)
    public enum Radius {
        /// Controls / buttons-as-rects.  · 14
        public static let control: CGFloat = 14
        /// Cards.  · 22
        public static let card: CGFloat = 22
        /// Sheets.  · 30
        public static let sheet: CGFloat = 30
        /// Register / status tags.  · 9  (kit-core.jsx:4 — not shown in the RadiiBoard)
        public static let tag: CGFloat = 9
        /// Pill / fully-rounded. Use `Capsule()` in practice; numeric sentinel = 999.
        public static let pill: CGFloat = 999
    }

    // MARK: Motion (theme.css:104–106)
    //  Springy ease. ⚠️ No explicit SwiftUI spring constants exist — motion is authored as
    //  cubic-bezier timing curves; the values below are those curves + durations.
    public enum Motion {
        /// Tap response, toggles.  · 140ms
        public static let durationQuick: TimeInterval = 0.14
        /// Transitions, card appearance.  · 260ms
        public static let durationStandard: TimeInterval = 0.26
        /// Mic, flip-card, scenes.  · 420ms
        public static let durationExpressive: TimeInterval = 0.42

        /// `--ease-std` cubic-bezier(.2,.7,.3,1) — standard / settle.
        public static let easeStandard = (c0x: 0.20, c0y: 0.70, c1x: 0.30, c1y: 1.00)
        /// `--ease-emph` cubic-bezier(.32,.72,0,1) — expressive enter.
        public static let easeEmphasized = (c0x: 0.32, c0y: 0.72, c1x: 0.00, c1y: 1.00)

        /// Ready-made animations.
        public static let quick      = Animation.timingCurve(0.20, 0.70, 0.30, 1.00, duration: durationQuick)
        public static let standard   = Animation.timingCurve(0.20, 0.70, 0.30, 1.00, duration: durationStandard)
        public static let expressive = Animation.timingCurve(0.32, 0.72, 0.00, 1.00, duration: durationExpressive)
    }

    // MARK: Register tags (kit-core.jsx:104–108)
    //  Monochrome, "fill-density coded": formal = solid invert, casual = light surface,
    //  slang = outline only. Three tiers ONLY.
    //  ⚠️ FLAG: the brief's ladder is formal/neutral/casual/slang, but the artifact defines
    //     NO `neutral` style — `casual` carries the RU label "нейтрально" (neutral). The Domain
    //     `Register` enum may still expose `.neutral`; map it to `.casual` styling until a real
    //     token is added — do NOT invent a distinct neutral appearance here.
    public struct RegisterStyle: Sendable {
        public let fill: Color
        public let foreground: Color
        public let border: Color
    }
    public enum Register {
        /// Solid invert chip.  · kit-core.jsx:105
        public static let formal = RegisterStyle(fill: Surface.invert, foreground: Content.onInvert, border: .clear)
        /// Light surface chip, hairline border.  · kit-core.jsx:106
        public static let casual = RegisterStyle(fill: Surface.secondary, foreground: Content.primary, border: Hairline.strong)
        /// Outline-only chip.  · kit-core.jsx:107
        public static let slang  = RegisterStyle(fill: .clear, foreground: Content.secondary, border: Hairline.strong)

        // Tag metrics  ·  kit-core.jsx:112–114
        public static let height: CGFloat = 22
        public static let paddingHorizontal: CGFloat = 9
        public static let radius: CGFloat = Radius.tag        // 9
        /// Label type: 10 / 700 / +0.4, UPPERCASE (a heavier override of `Text.caption2`; design 11 −1).
        public static let labelFont = Font.system(size: 10, weight: .bold)
        public static let labelTracking: CGFloat = 0.4
    }

    // MARK: Iconography — thin line (icons.jsx)
    public enum Icon {
        /// Default glyph box, 24×24 grid.  · icons.jsx:49,52
        public static let size: CGFloat = 24
        /// Default stroke weight for thin-line icons.  · icons.jsx:49
        public static let stroke: CGFloat = 1.7
        /// Stroke for a knockout glyph on a filled shape (e.g. checkmark on a solid circle).  · icons.jsx:22
        public static let strokeOnFill: CGFloat = 2.0

        /// Card action-row glyphs (play · explain · copy) — the secondary actions on a result card.
        /// Single source of truth so every card across all sections stays in lockstep.
        public static let cardAction: CGFloat = 14
        /// The save/bookmark glyph — kept a touch larger than the other card actions for emphasis.
        public static let cardActionProminent: CGFloat = 16
    }
}

// MARK: - Convenience view modifiers

public extension Font.Weight {
    /// Bridge to the UIKit weight used to measure the system font's natural line height.
    var uiKit: UIFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .regular:    return .regular
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }
}

public extension View {
    /// Apply a typography token (font + tracking + line height).
    func textStyle(_ token: Tokens.TextStyleToken) -> some View {
        self.font(token.font)
            .tracking(token.tracking)
            .lineSpacing(token.lineSpacing)
    }

    /// Apply a shadow token, resolving light/dark from the environment.
    func shadow(_ light: Tokens.ShadowToken, _ dark: Tokens.ShadowToken, scheme: ColorScheme) -> some View {
        let t = scheme == .dark ? dark : light
        return self.shadow(color: t.color, radius: t.radius, x: t.x, y: t.y)
    }
}
