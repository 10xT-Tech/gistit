//
//  PasteControlTests.swift
//  EnglishHelperTests
//
//  The system paste control is drawn by another process, and an app can be left without that
//  picture for good (see EHPasteButton.swift). What can be pinned here: the self-check's decision,
//  the process-wide answer, and — against the REAL pasteboard — that the slot is armed only by what
//  the control accepts.
//

import Testing
import UIKit
@testable import DesignSystem
@testable import Presentation

@MainActor
@Suite(.serialized)
struct PasteControlTests {

    private let drawn = CGSize(width: 87, height: 34)

    @Test func aControlWithItsPictureIsFine() {
        var emptyLooks = 0
        #expect(PasteControlCheck.verdict(onScreen: true, ownSize: drawn, emptyLooks: &emptyLooks) == .drawn)
    }

    /// Without a picture it has no size of its own — but one look isn't enough to say so.
    @Test func aControlLeftWithoutAPictureIsEmptyOnTheSecondLook() {
        var emptyLooks = 0
        #expect(PasteControlCheck.verdict(onScreen: true, ownSize: .zero, emptyLooks: &emptyLooks) == .lookAgain)
        #expect(PasteControlCheck.verdict(onScreen: true, ownSize: .zero, emptyLooks: &emptyLooks) == .empty)
    }

    /// Behind the screen (or not in a window yet) nothing is displayed, so nothing is judged — and
    /// what was seen before doesn't count either: a control made while the app was in the background
    /// must not be taken for an empty one.
    @Test func aControlNotOnScreenIsNotJudged() {
        var emptyLooks = 0
        #expect(PasteControlCheck.verdict(onScreen: true, ownSize: .zero, emptyLooks: &emptyLooks) == .lookAgain)
        #expect(PasteControlCheck.verdict(onScreen: false, ownSize: .zero, emptyLooks: &emptyLooks) == .lookAgain)
        #expect(PasteControlCheck.verdict(onScreen: false, ownSize: .zero, emptyLooks: &emptyLooks) == .lookAgain)
        #expect(PasteControlCheck.verdict(onScreen: true, ownSize: .zero, emptyLooks: &emptyLooks) == .lookAgain)
        #expect(PasteControlCheck.verdict(onScreen: true, ownSize: drawn, emptyLooks: &emptyLooks) == .drawn)
    }

    /// Once the process can't get the control drawn, it can't until relaunch: the answer is kept.
    @Test func unavailableStaysUnavailable() {
        let control = SystemPasteControl()
        #expect(control.isAvailable)
        control.markUnavailable()
        control.markUnavailable()
        #expect(!control.isAvailable)
    }

    /// The slot offers Paste for what the control ACCEPTS, in any item — not for `hasStrings`, which
    /// is also true for rich text without a plain-text form (the control greys itself out for it and
    /// the screen was left with a dead Paste and no Translate).
    @Test func theSlotIsArmedOnlyByWhatTheControlAccepts() {
        let pasteboard = UIPasteboard.general
        let saved = pasteboard.items
        defer { pasteboard.items = saved }
        let system = SystemPasteboard()
        let png = UIImage(systemName: "star")!.pngData()!

        pasteboard.string = "break a leg"
        #expect(system.hasText)
        pasteboard.items = []
        pasteboard.url = URL(string: "https://example.com")!
        #expect(system.hasText)
        pasteboard.setItems([["public.png": png], ["public.utf8-plain-text": "second item"]])
        #expect(system.hasText)

        pasteboard.setItems([["public.rtf": Data("{\\rtf1\\ansi hello}".utf8)]])
        #expect(pasteboard.hasStrings)          // what the slot used to go by
        #expect(!system.hasText)
        pasteboard.setItems([["public.png": png]])
        #expect(!system.hasText)
        pasteboard.items = []
        #expect(!system.hasText)
    }

    @Test func theClipboardsChangeIsSeen() {
        let pasteboard = UIPasteboard.general
        let saved = pasteboard.items
        defer { pasteboard.items = saved }
        let system = SystemPasteboard()
        pasteboard.string = "one"
        let before = system.changeCount
        pasteboard.string = "two"
        #expect(system.changeCount != before)
    }
}
