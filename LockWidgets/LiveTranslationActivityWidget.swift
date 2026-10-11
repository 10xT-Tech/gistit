//
//  LiveTranslationActivityWidget.swift
//  EnglishHelper — Lock Screen widgets (WidgetKit extension)
//
//  The Live Activity for a RUNNING online-translation session — the Voice-Memos-style banner that
//  stays visible when the screen locks mid-session: a pulsing record indicator (orange pause icon
//  while muted), the translation direction, a self-ticking elapsed timer, and PAUSE / STOP buttons.
//  The buttons are `LiveActivityIntent`s (Shared/LiveTranslationActivity.swift), so iOS runs them
//  in the app's process — no unlock, no app switch. Tapping the banner itself deep-links into the
//  Online screen via the same URL the Get it · Online widget uses.
//
//  Strings are English-only, matching the rest of this extension (widget gallery names are too).
//

import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

struct LiveTranslationActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveTranslationActivityAttributes.self) { context in
            LiveTranslationBanner(state: context.state)
                .widgetURL(URL(string: "englishhelper://getit-online"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RecordIndicator(isPaused: context.state.isPaused)
                        .font(.system(size: 26))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.direction).font(.headline)
                        ElapsedText(state: context.state)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 8) {
                        PauseButton(isPaused: context.state.isPaused)
                        StopButton()
                    }
                }
            } compactLeading: {
                RecordIndicator(isPaused: context.state.isPaused)
            } compactTrailing: {
                ElapsedText(state: context.state)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                RecordIndicator(isPaused: context.state.isPaused)
            }
        }
    }
}

/// The Lock Screen / banner presentation.
private struct LiveTranslationBanner: View {
    let state: LiveTranslationActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            RecordIndicator(isPaused: state.isPaused)
                .font(.system(size: 30))
            VStack(alignment: .leading, spacing: 2) {
                Text("Live translation \(state.direction)")
                    .font(.headline)
                ElapsedText(state: state)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            PauseButton(isPaused: state.isPaused)
            StopButton()
        }
        .padding(16)
    }
}

/// Red pulsing "recording" dot while listening; a steady orange pause glyph while muted.
private struct RecordIndicator: View {
    let isPaused: Bool
    var body: some View {
        Image(systemName: isPaused ? "pause.circle.fill" : "record.circle")
            .foregroundStyle(isPaused ? .orange : .red)
            .symbolEffect(.pulse, isActive: !isPaused)
    }
}

/// Elapsed session time. While LISTENING it ticks on its own (no activity updates needed);
/// while PAUSED it shows a static "Paused" so a muted session doesn't look like it's recording.
private struct ElapsedText: View {
    let state: LiveTranslationActivityAttributes.ContentState
    var body: some View {
        if state.isPaused {
            Text("Paused")
        } else {
            // Upper bound is only a formality for the ClosedRange — sessions auto-stop long before.
            Text(timerInterval: state.startedAt...state.startedAt.addingTimeInterval(12 * 3600),
                 countsDown: false)
        }
    }
}

private struct PauseButton: View {
    let isPaused: Bool
    var body: some View {
        Button(intent: ToggleLiveTranslationPauseIntent()) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.quaternary))
        }
        .buttonStyle(.plain)
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopLiveTranslationIntent()) {
            Image(systemName: "stop.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.quaternary))
        }
        .buttonStyle(.plain)
    }
}
