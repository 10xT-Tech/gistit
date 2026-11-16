//
//  LiveTranscriptTests.swift
//  EnglishHelperTests
//
//  The Online transcript on screen: the committed text is cut into blocks of whole paragraphs, one
//  `Text` each, so that a long session isn't laid out again in full on every update — and the stack
//  of them is the text, and measures as the single `Text` did.
//

import Testing
import Foundation
import SwiftUI
import UIKit
import Adapters
import DesignSystem
@testable import Presentation

@MainActor struct LiveTranscriptTests {
    private let boundary = SonioxTokenAccumulator.boundary

    private func text(of blocks: TranscriptBlocks) -> String {
        (blocks.closed + [blocks.open]).joined(separator: "\n")
    }

    private var samples: [String] {
        ["", "One.", "One.\n\nTwo.", "One.\n\n", "One." + boundary, "One." + boundary + "Two.\n\nThree.",
         "A\nB\n\nC", "A\n\n\nB", "A\n\n\n\nB", "Привет.\n\nКак дела? 👋\n\nХорошо."]
    }

    /// Nothing is lost or added by the cut, whatever the block size.
    @Test func theBlocksAreTheText() {
        for sample in samples {
            for size in [0, 3, 10, 2_000] {
                #expect(text(of: TranscriptBlocks(sample, blockSize: size)) == sample)
            }
        }
    }

    /// A block is whole paragraphs: closed at a paragraph break only, once it has its size — and it
    /// keeps the first of the break's two line breaks (the empty line it draws).
    @Test func aBlockClosesAtAParagraphBreakOnceItHasItsSize() {
        let paragraph = "One two three."                                    // 14 characters
        let source = Array(repeating: paragraph, count: 6).joined(separator: "\n\n")
        let perParagraph = TranscriptBlocks(source, blockSize: 0)
        #expect(perParagraph.closed == Array(repeating: paragraph + "\n", count: 5))
        #expect(perParagraph.open == paragraph)
        let pairs = TranscriptBlocks(source, blockSize: 20)                 // a paragraph is under it, two are over
        #expect(pairs.closed == Array(repeating: paragraph + "\n\n" + paragraph + "\n", count: 2))
        #expect(pairs.open == paragraph + "\n\n" + paragraph)
        #expect(TranscriptBlocks(source).closed.isEmpty)                    // far under a real block: one Text
    }

    /// The text grows token by token: reading only its new end gives the same cut as reading it
    /// all — and a block, once closed, never changes (that is what lets the screen leave it alone).
    @Test func growingTextIsCutTheSameAndClosedBlocksStay() {
        var accumulator = SonioxTokenAccumulator()
        var grown = TranscriptBlocks()
        var before: [String] = []
        for step in 0..<400 {
            var tokens = [SonioxToken(text: " word\(step)", isFinal: true, translationStatus: "original")]
            if step % 7 == 6 { tokens.append(SonioxToken(text: "<end>", isFinal: true, translationStatus: nil)) }
            accumulator.ingest(tokens)
            if step == 200 { accumulator.insertBoundary() }
            let text = accumulator.originalFinal
            grown.take(text, blockSize: 60)
            #expect(grown == TranscriptBlocks(text, blockSize: 60))
            #expect(Array(grown.closed.prefix(before.count)) == before)
            before = grown.closed
        }
        #expect(before.count > 20)
    }

    /// Another text (a new session) is cut from the start — also when it is longer than the old one
    /// and the screen never showed an empty pane in between.
    @Test func anotherTextStartsOver() {
        let first = Array(repeating: "One two three.", count: 10).joined(separator: "\n\n")
        let second = Array(repeating: "Four five six, seven.", count: 12).joined(separator: "\n\n")
        for other in [second, "Short.", "", String(first.dropLast(40))] {
            var blocks = TranscriptBlocks(first, blockSize: 20)
            blocks.take(other, blockSize: 20)
            #expect(blocks == TranscriptBlocks(other, blockSize: 20))
            #expect(text(of: blocks) == other)
        }
    }

    /// The stack of `Text`s measures as the one `Text` with the whole transcript did — the scroll
    /// sync of the two panes works on that height. Each `Text` rounds its own height, hence a
    /// fraction of a point a block.
    @Test func theStackMeasuresAsTheSingleText() {
        func height(_ view: some View) -> CGFloat {
            UIHostingController(rootView: view.frame(maxWidth: .infinity, alignment: .leading))
                .sizeThatFits(in: CGSize(width: 340, height: CGFloat.greatestFiniteMagnitude)).height
        }
        let long = "Three words go here and wrap around the line at some point, surely they do."
        let cases: [(String, String)] = [
            ("One.", ""), ("One.", " Two"), ("One.", "\n\nTwo"), ("One.\n\n" + long, " tail"),
            ("One.\n\n", ""), ("One.\n\n", "Two"), ("One." + boundary, ""), ("One." + boundary, "Two"),
            ("One." + boundary + long + "\n\nThree.", " four"), ("", "only the tail"),
        ]
        for (final, pending) in cases {
            let single = height(Text("\(Text(final))\(Text(pending))").textStyle(Tokens.Text.body)
                .fixedSize(horizontal: false, vertical: true))
            let stack = height(TranscriptText(finalText: final, pendingText: pending, blockSize: 0))
            let blocks = CGFloat(TranscriptBlocks(final, blockSize: 0).closed.count)
            #expect(abs(stack - single) <= 0.5 * (blocks + 1), "\(final.debugDescription) + \(pending.debugDescription): \(stack) vs \(single)")
        }
    }
}
