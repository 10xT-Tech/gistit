//
//  ProgressLine.swift
//  EnglishHelper — DesignSystem
//
//  A thin progress line: what's done in green, and — optionally — what's under way ahead of it in
//  grey (sent to the model, waiting for its answer), so the green catches up with the grey. The
//  numbers are always spelled out next to it; the line itself is hidden from VoiceOver unless the
//  caller gives it a label and value.
//

import SwiftUI

public struct ProgressLine: View {
    private let done: Double
    private let pending: Double
    private let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `done` and `pending` are fractions of the whole (0…1); `pending` counts from the start, so it's
    /// never drawn shorter than `done`.
    public init(done: Double, pending: Double = 0, height: CGFloat = 6) {
        self.done = Self.clamp(done)
        self.pending = max(Self.clamp(pending), Self.clamp(done))
        self.height = height
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.Chart.progressTrack)
                if pending > done {
                    Capsule()
                        .fill(Tokens.Chart.progressPending)
                        .frame(width: width(pending, in: geometry.size.width))
                }
                if done > 0 {
                    Capsule()
                        .fill(Tokens.Chart.progressDone)
                        .frame(width: width(done, in: geometry.size.width))
                }
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: done)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: pending)
        .accessibilityHidden(true)
    }

    /// A sliver of a started part stays visible (at least the line's height).
    private func width(_ fraction: Double, in total: CGFloat) -> CGFloat {
        max(height, total * fraction)
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// The key under a two-part line: a grey dot "sent", a green dot "done".
public struct ProgressLineLegend: View {
    private let pendingLabel: String
    private let doneLabel: String

    public init(pending: String, done: String) {
        self.pendingLabel = pending
        self.doneLabel = done
    }

    public var body: some View {
        HStack(spacing: Tokens.Space.s12) {
            item(Tokens.Chart.progressPending, pendingLabel)
            item(Tokens.Chart.progressDone, doneLabel)
        }
        .textStyle(Tokens.Text.caption)
        .foregroundStyle(Tokens.Content.secondary)
    }

    private func item(_ color: Color, _ label: String) -> some View {
        HStack(spacing: Tokens.Space.s4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}
