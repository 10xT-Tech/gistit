//
//  StorageUsageReader.swift
//  EnglishHelper — Data (SwiftData + files)
//
//  Disk usage for Settings (`StorageUsageReading`): cache and history are summed from the row
//  CONTENTS (key/input text + payload JSON) — all three tables share ONE SQLite file, so per-kind
//  file sizes don't exist and SQLite overhead can't be attributed — while session audio is the
//  actual size of the files in the recordings directory. The deck — phrases, their flashcards and
//  the review log — is reported by the repositories that hold it in memory (`DeckFootprintReporting`):
//  how many, the content on disk, and what the in-memory copy takes. Everything is best-effort: a
//  failed read contributes zero rather than failing the Settings screen.
//

import Foundation
import SwiftData
import Domain

/// What a repository's part of the deck takes: how many items, their content as stored (texts and
/// fields — SQLite's own overhead can't be attributed), and an ESTIMATE of the memory its in-memory
/// copy occupies (the values, their text storage, the collection's spare room).
public struct DeckFootprint: Sendable, Equatable {
    public let count: Int
    public let contentBytes: Int
    public let memoryBytes: Int

    public init(count: Int, contentBytes: Int, memoryBytes: Int) {
        self.count = count
        self.contentBytes = contentBytes
        self.memoryBytes = memoryBytes
    }
}

public extension DeckFootprint {
    static let none = DeckFootprint(count: 0, contentBytes: 0, memoryBytes: 0)

    /// The phrases: their texts as stored (+ id, date, flag), and in memory the values plus the text
    /// storage of every string too long to live inside the value (over 15 bytes) and the synonyms' array.
    init(expressions: [Domain.Expression]) {
        var content = 0, heap = 0
        for expression in expressions {
            for text in [expression.en, expression.ru, expression.example, expression.context] + expression.synonyms {
                let bytes = text.utf8.count
                content += bytes
                if bytes > 15 { heap += bytes + 32 }
            }
            content += 25
            heap += 32 + expression.synonyms.count * MemoryLayout<String>.stride
        }
        self.init(count: expressions.count, contentBytes: content,
                  memoryBytes: expressions.count * MemoryLayout<Domain.Expression>.stride + heap)
    }

    /// The cards: a row is two ids, the direction's and the state's names, seven numbers and dates;
    /// in memory, the value and its key in a dictionary that keeps some room spare.
    init(cardCount: Int) {
        self.init(count: cardCount, contentBytes: cardCount * Self.cardRowBytes,
                  memoryBytes: cardCount * (MemoryLayout<ReviewCard>.stride + MemoryLayout<UUID>.stride) * 4 / 3)
    }

    static let cardRowBytes = 130
}

public protocol DeckFootprintReporting: Sendable {
    func footprint() async -> DeckFootprint
}

/// The deck's part of the storage report alone — for boots without a SwiftData store (UI tests on
/// in-memory repositories), so Settings still says what the deck holds.
public struct DeckStorageUsageReader: StorageUsageReading {
    private let phrases: any DeckFootprintReporting
    private let cards: any DeckFootprintReporting

    public init(phrases: any DeckFootprintReporting, cards: any DeckFootprintReporting) {
        self.phrases = phrases
        self.cards = cards
    }

    public func usage() async -> StorageUsage {
        let phrases = await phrases.footprint(), cards = await cards.footprint()
        return StorageUsage(cacheBytes: 0, historyBytes: 0, audioBytes: 0,
                            deckBytes: phrases.contentBytes + cards.contentBytes,
                            deckMemoryBytes: phrases.memoryBytes + cards.memoryBytes,
                            phraseCount: phrases.count, cardCount: cards.count)
    }
}

@ModelActor
public actor StorageUsageReader: StorageUsageReading {
    /// Nil → the shared SessionRecordings directory (same resolution as the recorder/player).
    /// Tests inject a temp directory so the numbers are deterministic on any host.
    /// `var`, not `let`: the optional needs the implicit nil default so the @ModelActor-generated
    /// `init(modelContainer:)` still compiles (same pattern as SwiftDataHistoryRepository).
    private var recordingsDirectory: URL?
    /// The repositories holding the deck (nil in tests that don't care: the deck then reports zero).
    private var phrases: (any DeckFootprintReporting)?
    private var cards: (any DeckFootprintReporting)?

    /// Designated init with the directory override (@ModelActor only generates
    /// `init(modelContainer:)`, which leaves `recordingsDirectory` nil).
    public init(modelContainer: ModelContainer, recordingsDirectory: URL?,
                phrases: (any DeckFootprintReporting)? = nil, cards: (any DeckFootprintReporting)? = nil) {
        let context = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.modelContainer = modelContainer
        self.recordingsDirectory = recordingsDirectory
        self.phrases = phrases
        self.cards = cards
    }

    public func usage() async -> StorageUsage {
        // Row counts are capped (cache 500, history 200), so loading the payloads to sum them is cheap.
        let cacheBytes = ((try? modelContext.fetch(FetchDescriptor<CachedTranslationModel>())) ?? [])
            .reduce(0) { $0 + $1.value.count + $1.key.utf8.count }
        let historyBytes = ((try? modelContext.fetch(FetchDescriptor<HistoryModel>())) ?? [])
            .reduce(0) { $0 + $1.resultData.count + $1.inputText.utf8.count }
        let phrases = await self.phrases?.footprint() ?? .none
        let cards = await self.cards?.footprint() ?? .none
        // The review log (one row per answer) isn't kept in memory: counted, not read.
        let logRows = self.cards == nil ? 0 : ((try? modelContext.fetchCount(FetchDescriptor<ReviewLogModel>())) ?? 0)
        return StorageUsage(cacheBytes: cacheBytes, historyBytes: historyBytes, audioBytes: audioBytes(),
                            deckBytes: phrases.contentBytes + cards.contentBytes + logRows * Self.logRowBytes,
                            deckMemoryBytes: phrases.memoryBytes + cards.memoryBytes,
                            phraseCount: phrases.count, cardCount: cards.count)
    }

    /// A review-log row: two ids, the rating, the state's name, a date.
    static let logRowBytes = 60

    private func audioBytes() -> Int {
        guard let dir = recordingsDirectory ?? (try? RecordingsDirectory.url()),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
