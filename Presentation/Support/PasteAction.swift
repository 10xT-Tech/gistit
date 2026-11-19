//
//  PasteAction.swift
//  EnglishHelper — Presentation (support)
//
//  The PASTE persona of the action slot on Say it and Get it. Normally the SYSTEM paste control: its
//  tap is the user's consent, so iOS never asks "Allow Paste?". When iOS can't draw that control in
//  this process any more (`SystemPasteControl` — the slot was an empty, dead rectangle until the app
//  was relaunched), the app's own button takes its place: it reads the clipboard itself, iOS asks
//  the user once per new content, and the paste works.
//

import DesignSystem
import SwiftUI

struct PasteAction: View {
    let accessibilityID: String
    /// The system control delivered the clipboard's text.
    let onPaste: @MainActor (String) -> Void
    /// The app's own button was tapped: read the clipboard and paste.
    let onReadAndPaste: @MainActor () -> Void

    var body: some View {
        if SystemPasteControl.shared.isAvailable {
            EHPasteButton(onPaste: onPaste) { SystemPasteControl.shared.markUnavailable() }
                .frame(maxWidth: .infinity, minHeight: 50)
                .accessibilityIdentifier(accessibilityID)
        } else {
            EHButton(Loc.t("Вставить", "Paste", "Coller", "Pegar", "Einfügen", "Incolla"),
                     icon: "doc.on.clipboard", kind: .primary, fillWidth: true,
                     accessibilityID: accessibilityID, action: onReadAndPaste)
        }
    }
}
