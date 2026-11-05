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

import SwiftUI
import UIKit

public struct EHPasteButton: UIViewRepresentable {
    // @MainActor-isolated so the value is Sendable — NSItemProvider delivers the paste on a
    // background queue and the coordinator hops it back to the main actor.
    private let onPaste: @MainActor (String) -> Void

    /// `onPaste` receives the pasted string on the main actor.
    public init(onPaste: @escaping @MainActor (String) -> Void) {
        self.onPaste = onPaste
    }

    public func makeUIView(context: Context) -> UIPasteControl {
        let config = UIPasteControl.Configuration()
        config.displayMode = .iconAndLabel
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor(Tokens.Surface.invert)
        config.baseForegroundColor = UIColor(Tokens.Content.onInvert)
        let control = UIPasteControl(configuration: config)
        control.target = context.coordinator
        return control
    }

    public func updateUIView(_ uiView: UIPasteControl, context: Context) {
        context.coordinator.onPaste = onPaste
    }

    /// Fill whatever frame the layout proposes — the pill must match its EHButton/MicButton
    /// row-mates (fillWidth, minHeight 50) instead of hugging the system control's intrinsic size.
    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPasteControl, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onPaste: onPaste) }

    /// The control's paste TARGET: `pasteConfiguration` declares what it accepts (the control
    /// auto-disables itself when the pasteboard holds nothing acceptable), `paste(itemProviders:)`
    /// receives the content of the consented tap.
    public final class Coordinator: UIResponder {
        var onPaste: @MainActor (String) -> Void

        init(onPaste: @escaping @MainActor (String) -> Void) {
            self.onPaste = onPaste
            super.init()
            pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        }

        public override func paste(itemProviders: [NSItemProvider]) {
            guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
            _ = provider.loadObject(ofClass: NSString.self) { [onPaste] object, _ in
                guard let text = (object as? NSString).map(String.init) else { return }
                Task { @MainActor in onPaste(text) }
            }
        }
    }
}
