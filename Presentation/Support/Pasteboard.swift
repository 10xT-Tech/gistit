//
//  Pasteboard.swift
//  EnglishHelper — Presentation (support)
//
//  The clipboard behind the paste-into-input affordance. A protocol (not UIPasteboard directly) so
//  view-model tests can inject canned clipboard state, and `ClipboardWatch` — the one place that
//  decides whether the action slot offers Paste (Say it and Get it share it).
//
//  PRIVACY: `hasText` and `changeCount` are metadata — they never trigger the iOS paste banner or the
//  "Allow Paste?" confirmation. The CONTENT normally isn't read here at all: the paste goes through
//  the system UIPasteControl (`EHPasteButton`), whose tap is itself the user's pasteboard consent.
//  `readText()` is the exception, for when iOS can't draw that control (`SystemPasteControl`): the
//  app's own Paste button reads the clipboard, and iOS asks the user first.
//

import DesignSystem
import Foundation
import Observation
import UIKit

public protocol PasteboardReading: Sendable {
    /// Whether the clipboard holds something the Paste button can take (metadata, no paste notification).
    @MainActor var hasText: Bool { get }
    /// Changes with every change of the clipboard's content (metadata).
    @MainActor var changeCount: Int { get }
    /// READS the clipboard's text — iOS asks the user to allow it, and the answer is awaited without
    /// holding the main thread. Nil when there is none or the user said no.
    @MainActor func readText() async -> String?
}

@MainActor
public struct SystemPasteboard: PasteboardReading {
    public init() {}

    /// By the types the system paste control accepts, in ANY item — not `hasStrings`: that one is
    /// also true for rich text without a plain-text form, which the control refuses (the slot then
    /// held a greyed-out Paste and no Translate), and it looks at the first item only.
    public var hasText: Bool {
        UIPasteboard.general.contains(pasteboardTypes: EHPasteButton.acceptedTypeIdentifiers, inItemSet: nil)
    }

    public var changeCount: Int { UIPasteboard.general.changeCount }

    /// Through the item provider, like the system control's own delivery: the load is asynchronous,
    /// so the app isn't frozen behind iOS's question (`UIPasteboard.string` blocks until it is answered).
    public func readText() async -> String? {
        let providers = UIPasteboard.general.itemProviders
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString).map(String.init))
            }
        }
    }
}

/// Whether the action slot may offer PASTE right now: the clipboard holds text the button can take,
/// and that text hasn't already turned out to be nothing (empty, only spaces, refused by the user).
@MainActor
@Observable
public final class ClipboardWatch {
    public private(set) var hasText = false

    @ObservationIgnored private let pasteboard: any PasteboardReading
    /// The clipboard content that gave nothing usable: Paste stays off until the clipboard CHANGES.
    /// (It used to be switched off for a moment only — the next look at the clipboard, a second
    /// later, brought back a Paste that pasted nothing, again and again.)
    @ObservationIgnored private var unusableChange: Int?

    public init(_ pasteboard: any PasteboardReading) {
        self.pasteboard = pasteboard
    }

    /// Look at the clipboard's METADATA again (never triggers the iOS paste banner).
    public func refresh() {
        let now = pasteboard.hasText && pasteboard.changeCount != unusableChange
        if now != hasText { hasText = now }   // equal → no @Observable churn
    }

    /// Keep `hasText` honest for as long as the screen is visible. iOS posts
    /// `UIPasteboard.changedNotification` only for changes made by THIS app or when the app becomes
    /// active — a change made by another process while we are already in the foreground (Universal
    /// Clipboard from a Mac, a password manager's auto-clear, Shortcuts, a keyboard extension) is
    /// silent. Left unrefreshed, the slot either kept a Paste control the system had already greyed
    /// out (no Explain/Translate anywhere on the screen) or a disabled mode button with text one tap
    /// away. The interval is a parameter so tests can run the loop fast. Runs until cancelled — bind
    /// it to the screen with `.task`.
    public func monitor(every interval: Duration = .seconds(1)) async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: interval)
        }
    }

    /// What the clipboard gave had nothing to put in the field.
    public func markUnusable() {
        unusableChange = pasteboard.changeCount
        if hasText { hasText = false }
    }

    /// READ the clipboard (iOS asks the user) — the app's own Paste button, see the header.
    public func read() async -> String? { await pasteboard.readText() }
}
