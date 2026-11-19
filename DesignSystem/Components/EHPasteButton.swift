//
//  EHPasteButton.swift
//  EnglishHelper — DesignSystem
//
//  The SYSTEM paste control (UIPasteControl) styled like the primary EHButton. A custom button
//  reading UIPasteboard programmatically makes iOS show the "Allow Paste?" dialog on every new
//  clipboard content — there is no API to remember that consent. Tapping the system control IS the
//  consent, so it never prompts. The trade-offs: the label text/font are the system's ("Paste",
//  localized to the SYSTEM language, not the in-app one), and its look is only configurable through
//  UIPasteControl.Configuration — capsule + inverted colors below get it close to EHButton.
//
//  THE CONTROL IS DRAWN BY ANOTHER PROCESS — iOS's `com.apple.UIKit.SecureControlService` — and an app
//  never gets that picture again once the service has died under it: every control created afterwards
//  is an EMPTY, dead rectangle (accessibility still says "Paste, enabled") until the app is relaunched.
//  Restarting the service, going behind and back, a new control — nothing brings it back within the
//  process (reproduced on the Simulator by killing the service; Apple's forums describe the same
//  "sometimes disappears, a restart helps"). So the control checks itself once it is on screen — a
//  control that got its picture has a size of its own, one that didn't reports zero — and says so
//  (`onUnavailable`, `SystemPasteControl`); the caller then shows a button of its own instead.
//

import SwiftUI
import UIKit

/// Whether THIS PROCESS can still get the system paste control drawn. Once it can't, it can't until
/// the app is relaunched — so the answer is kept for the process, and the next slot starts with the
/// app's own button instead of flashing an empty one first.
@MainActor
@Observable
public final class SystemPasteControl {
    public static let shared = SystemPasteControl()
    public private(set) var isAvailable = true

    public init() {}

    public func markUnavailable() {
        if isAvailable { isAvailable = false }
    }
}

public struct EHPasteButton: View {
    /// What the control takes from the clipboard (it is disabled — greyed out — for anything else).
    /// The caller arms the Paste slot by the SAME list, so the slot never holds a greyed-out control.
    public static let acceptedTypeIdentifiers: [String] = NSString.readableTypeIdentifiersForItemProvider

    // @MainActor-isolated so the value is Sendable — NSItemProvider delivers the paste on a
    // background queue and the coordinator hops it back to the main actor.
    private let onPaste: @MainActor (String) -> Void
    private let onUnavailable: @MainActor () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// `onPaste` receives the pasted string on the main actor; `onUnavailable` is called when iOS
    /// didn't draw the control (see the header) — show something else in its place.
    public init(onPaste: @escaping @MainActor (String) -> Void,
                onUnavailable: @escaping @MainActor () -> Void = {}) {
        self.onPaste = onPaste
        self.onUnavailable = onUnavailable
    }

    public var body: some View {
        // The control takes its colors ONCE, when it is made, and keeps them through a light/dark
        // switch (on a dark screen it stayed a black pill with a white label) — a new scheme makes
        // a new control.
        Control(onPaste: onPaste, onUnavailable: onUnavailable, scheme: colorScheme)
            .id(colorScheme)
    }
}

private struct Control: UIViewRepresentable {
    let onPaste: @MainActor (String) -> Void
    let onUnavailable: @MainActor () -> Void
    let scheme: ColorScheme

    func makeUIView(context: Context) -> UIPasteControl {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let config = UIPasteControl.Configuration()
        config.displayMode = .iconAndLabel
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor(Tokens.Surface.invert).resolvedColor(with: traits)
        config.baseForegroundColor = UIColor(Tokens.Content.onInvert).resolvedColor(with: traits)
        let control = UIPasteControl(configuration: config)
        control.target = context.coordinator
        context.coordinator.watch(control)
        return control
    }

    func updateUIView(_ uiView: UIPasteControl, context: Context) {
        context.coordinator.onPaste = onPaste
        context.coordinator.onUnavailable = onUnavailable
    }

    static func dismantleUIView(_ uiView: UIPasteControl, coordinator: Coordinator) {
        coordinator.stopWatching()
    }

    /// Fill whatever frame the layout proposes — the pill must match its EHButton/MicButton
    /// row-mates (fillWidth, minHeight 50) instead of hugging the system control's intrinsic size.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPasteControl, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPaste: onPaste, onUnavailable: onUnavailable) }

    /// The control's paste TARGET: `pasteConfiguration` declares what it accepts (the control
    /// auto-disables itself when the pasteboard holds nothing acceptable), `paste(itemProviders:)`
    /// receives the content of the consented tap.
    final class Coordinator: UIResponder {
        var onPaste: @MainActor (String) -> Void
        var onUnavailable: @MainActor () -> Void
        private var check: Task<Void, Never>?

        init(onPaste: @escaping @MainActor (String) -> Void, onUnavailable: @escaping @MainActor () -> Void) {
            self.onPaste = onPaste
            self.onUnavailable = onUnavailable
            super.init()
            pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        }

        override func paste(itemProviders: [NSItemProvider]) {
            guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
            _ = provider.loadObject(ofClass: NSString.self) { [onPaste] object, _ in
                guard let text = (object as? NSString).map(String.init) else { return }
                Task { @MainActor in onPaste(text) }
            }
        }

        /// Did iOS draw it? The picture arrives when the control is first displayed, and with it the
        /// control's own size; a control left without one keeps reporting zero. Judged only while the
        /// app is ACTIVE and the control is in a window (nothing is displayed behind the screen — a
        /// control made there would look "empty" for no reason), and only when it stays so for a
        /// second look.
        func watch(_ control: UIPasteControl) {
            check?.cancel()
            check = Task { @MainActor [weak self, weak control] in
                var emptyLooks = 0
                for _ in 0..<PasteControlCheck.looks {
                    try? await Task.sleep(for: PasteControlCheck.interval)
                    guard !Task.isCancelled, let self, let control else { return }
                    let onScreen = control.window != nil && !control.bounds.isEmpty
                        && UIApplication.shared.applicationState == .active
                    switch PasteControlCheck.verdict(onScreen: onScreen, ownSize: control.intrinsicContentSize,
                                                     emptyLooks: &emptyLooks) {
                    case .drawn: return
                    case .empty: self.onUnavailable(); return
                    case .lookAgain: continue
                    }
                }
            }
        }

        func stopWatching() {
            check?.cancel()
            check = nil
        }
    }
}

/// The decision of the control's self-check, kept apart from UIKit so it can be tested.
enum PasteControlCheck {
    enum Verdict: Equatable { case drawn, empty, lookAgain }

    static let interval: Duration = .milliseconds(150)
    /// How long a control is watched for (a slot may be made long before it gets on screen).
    static let looks = 60
    /// Looks in a row, on screen, without a picture before the control counts as empty.
    static let emptyLooksNeeded = 2

    static func verdict(onScreen: Bool, ownSize: CGSize, emptyLooks: inout Int) -> Verdict {
        guard onScreen else { emptyLooks = 0; return .lookAgain }
        if ownSize.width > 0, ownSize.height > 0 { return .drawn }
        emptyLooks += 1
        return emptyLooks >= emptyLooksNeeded ? .empty : .lookAgain
    }
}
