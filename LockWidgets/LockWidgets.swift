//
//  LockWidgets.swift
//  EnglishHelper — Lock Screen widgets (WidgetKit extension)
//
//  Seven accessoryCircular Lock Screen widgets — one per scenario — that DEEP-LINK straight in via the
//  englishhelper:// scheme and (per RootView) open the camera, mic, or live session on arrival:
//
//    See it · Explain     seeit            See it · Translate     seeit-translate
//    Get it · Explain      getit            Get it · Translate      getit-translate
//    Get it · Online       getit-online
//    Say it · How to say   sayit            Say it · What to say    sayit-what
//
//  The icon encodes TWO axes so all seven read apart: INPUT MODALITY = the centered base glyph (camera /
//  character bubble / mic) and MODE = a small corner glyph (lightbulb for Explain / What-to-say, globe
//  for Translate / How-to-say, radiowaves for Online live translation).
//
//  Each widget is USER-CONFIGURABLE (AppIntentConfiguration): when you add or edit it you pick an
//  appearance — Standard (frosted disc + thin ring), Bordered (bold ring), or Filled (solid disc).
//  NOTE: the Lock Screen renders accessory widgets monochrome/vibrant, so literal colors (the black/gray
//  of typical Home-Screen icons) are not possible here — the three styles differ by ring weight + fill.
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - User-selectable appearance

enum WidgetStyle: String, AppEnum {
    case standard, bordered, filled

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Appearance" }
    static var caseDisplayRepresentations: [WidgetStyle: DisplayRepresentation] {
        [
            .standard: DisplayRepresentation(title: "Standard", subtitle: "Frosted disc, thin ring"),
            .bordered: DisplayRepresentation(title: "Bordered", subtitle: "Bold circular border"),
            .filled:   DisplayRepresentation(title: "Filled", subtitle: "Solid disc"),
        ]
    }
}

struct StyleIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Appearance" }
    static var description: IntentDescription { "Choose how the widget looks." }
    @Parameter(title: "Appearance", default: .standard) var style: WidgetStyle
}

// MARK: - Timeline (static launcher; carries the chosen style)

private struct LockEntry: TimelineEntry { let date: Date; let style: WidgetStyle }

private struct LockProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LockEntry { LockEntry(date: .now, style: .standard) }
    func snapshot(for configuration: StyleIntent, in context: Context) async -> LockEntry {
        LockEntry(date: .now, style: configuration.style)
    }
    func timeline(for configuration: StyleIntent, in context: Context) async -> Timeline<LockEntry> {
        Timeline(entries: [LockEntry(date: .now, style: configuration.style)], policy: .never)
    }
}

// MARK: - Reusable circular face (renders per chosen style)

private struct WidgetFace: View {
    let modality: String   // camera.fill / character.bubble.fill / mic.fill
    let mode: String       // lightbulb.fill (Explain / What-to-say) | globe (Translate / How-to-say)
    let style: WidgetStyle

    var body: some View {
        Image(systemName: modality)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: mode)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)
                    .offset(x: 5, y: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)   // fill the circular slot
            .overlay {
                switch style {
                case .standard: Circle().strokeBorder(.primary, lineWidth: 1.5)
                case .bordered: Circle().strokeBorder(.primary, lineWidth: 3)
                case .filled:   EmptyView()                     // the fill is the look, no ring
                }
            }
            .widgetAccentable()
            .containerBackground(for: .widget) {
                switch style {
                case .filled: Circle().fill(.primary.opacity(0.45))   // solid disc
                default:      AccessoryWidgetBackground()             // frosted disc
                }
            }
    }
}

// MARK: - The six widgets (each its own STABLE kind + deep link)

struct SeeItExplainWidget: Widget {
    let kind = "tech.10xt.englishhelper.widget.seeit"   // STABLE — do not change post-ship
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: StyleIntent.self, provider: LockProvider()) { entry in
            WidgetFace(modality: "camera.fill", mode: "lightbulb.fill", style: entry.style)
                .widgetURL(URL(string: "englishhelper://seeit"))
        }
        .configurationDisplayName("See it · Explain")
        .description("Camera → explain what it shows.")
        .supportedFamilies([.accessoryCircular])
        .contentMarginsDisabled()
    }
}

struct SeeItTranslateWidget: Widget {
    let kind = "tech.10xt.englishhelper.widget.seeit.translate"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: StyleIntent.self, provider: LockProvider()) { entry in
            WidgetFace(modality: "camera.fill", mode: "globe", style: entry.style)
                .widgetURL(URL(string: "englishhelper://seeit-translate"))
        }
        .configurationDisplayName("See it · Translate")
        .description("Camera → translate the text in it.")
        .supportedFamilies([.accessoryCircular])
        .contentMarginsDisabled()
    }
}

struct GetItExplainWidget: Widget {
    let kind = "tech.10xt.englishhelper.widget.getit"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: StyleIntent.self, provider: LockProvider()) { entry in
            WidgetFace(modality: "character.bubble.fill", mode: "lightbulb.fill", style: entry.style)
                .widgetURL(URL(string: "englishhelper://getit"))
        }
        .configurationDisplayName("Get it · Explain")
        .description("Explain a word or phrase.")
        .supportedFamilies([.accessoryCircular])
        .contentMarginsDisabled()
    }
}

struct GetItTranslateWidget: Widget {
    let kind = "tech.10xt.englishhelper.widget.getit.translate"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: StyleIntent.self, provider: LockProvider()) { entry in
            WidgetFace(modality: "character.bubble.fill", mode: "globe", style: entry.style)
                .widgetURL(URL(string: "englishhelper://getit-translate"))
        }
        .configurationDisplayName("Get it · Translate")
        .description("Translate a word or phrase.")
        .supportedFamilies([.accessoryCircular])
        .contentMarginsDisabled()
    }
}

struct GetItOnlineWidget: Widget {
    let kind = "tech.10xt.englishhelper.widget.getit.online"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: StyleIntent.self, provider: LockProvider()) { entry in
            WidgetFace(modality: "character.bubble.fill", mode: "dot.radiowaves.left.and.right", style: entry.style)
                .widgetURL(URL(string: "englishhelper://getit-online"))
        }
        .configurationDisplayName("Get it · Online")
        .description("Listen and translate speech live.")
        .supportedFamilies([.accessoryCircular])
        .contentMarginsDisabled()
    }
}

struct SayItHowWidget: Widget {
    let kind = "tech.10xt.englishhelper.widget.sayit"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: StyleIntent.self, provider: LockProvider()) { entry in
            WidgetFace(modality: "mic.fill", mode: "globe", style: entry.style)
                .widgetURL(URL(string: "englishhelper://sayit"))
        }
        .configurationDisplayName("Say it · How to say")
        .description("Learn how to say something.")
        .supportedFamilies([.accessoryCircular])
        .contentMarginsDisabled()
    }
}

struct SayItWhatWidget: Widget {
    let kind = "tech.10xt.englishhelper.widget.sayit.what"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: StyleIntent.self, provider: LockProvider()) { entry in
            WidgetFace(modality: "mic.fill", mode: "lightbulb.fill", style: entry.style)
                .widgetURL(URL(string: "englishhelper://sayit-what"))
        }
        .configurationDisplayName("Say it · What to say")
        .description("Ideas for what to say in a situation.")
        .supportedFamilies([.accessoryCircular])
        .contentMarginsDisabled()
    }
}

@main
struct LockWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SeeItExplainWidget()
        SeeItTranslateWidget()
        GetItExplainWidget()
        GetItTranslateWidget()
        GetItOnlineWidget()
        SayItHowWidget()
        SayItWhatWidget()
        LiveTranslationActivityWidget()   // the running online session on the Lock Screen
    }
}
