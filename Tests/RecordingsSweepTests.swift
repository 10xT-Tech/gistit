//
//  RecordingsSweepTests.swift
//  EnglishHelperTests
//
//  The launch sweep of orphaned session recordings deletes only what history can vouch is orphaned:
//  nothing on the in-memory fallback store (its empty history would condemn every recording the rows
//  on disk still point at), nothing when a history row can't be read or the read fails, and never a
//  file created in this launch (a session being recorded isn't in history yet). On disk, a file
//  newer than the cut-off stays.
//

import Testing
import Foundation
import SwiftData
import Domain
import Adapters

@Suite struct RecordingsSweepTests {
    private let launch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func session(_ fileName: String?) -> HistoryEntry {
        HistoryEntry(inputText: "bonjour", result: .liveTranslation(original: "bonjour", ru: "hello",
                                                                    audioFileName: fileName, duration: 5))
    }

    @Test func deletesOnlyTheOrphans() async {
        let recordings = MockSessionRecordings(existing: ["kept.m4a", "orphan.m4a"])
        let sut = RequestHistoryInteractor(history: MockHistoryRepository(seed: [session("kept.m4a"), session(nil)]),
                                           recordings: recordings)
        await sut.sweepOrphanedRecordings(createdBefore: launch, usingFallbackStore: false)
        #expect(recordings.deleted == ["orphan.m4a"])
        #expect(recordings.exists(fileName: "kept.m4a"))
    }

    /// The store on disk didn't open: history is an empty stand-in, the recordings are not orphans.
    @Test func theFallbackStoreSweepsNothing() async {
        let recordings = MockSessionRecordings(existing: ["a.m4a", "b.m4a"])
        let sut = RequestHistoryInteractor(history: MockHistoryRepository(), recordings: recordings)
        await sut.sweepOrphanedRecordings(createdBefore: launch, usingFallbackStore: true)
        #expect(recordings.deleted.isEmpty)
    }

    /// A session started at launch (a widget) records into a file history doesn't know yet.
    @Test func aRecordingOfThisLaunchStays() async {
        let recordings = MockSessionRecordings(
            existing: ["old.m4a", "recording-now.m4a"],
            createdAt: ["old.m4a": launch.addingTimeInterval(-3600), "recording-now.m4a": launch.addingTimeInterval(2)])
        let sut = RequestHistoryInteractor(history: MockHistoryRepository(), recordings: recordings)
        await sut.sweepOrphanedRecordings(createdBefore: launch, usingFallbackStore: false)
        #expect(recordings.deleted == ["old.m4a"])
    }

    @Test func aFailedOrUnsureHistoryReadSweepsNothing() async {
        for history in [UnsureHistory(fails: true), UnsureHistory(fails: false)] {
            let recordings = MockSessionRecordings(existing: ["a.m4a"])
            let sut = RequestHistoryInteractor(history: history, recordings: recordings)
            await sut.sweepOrphanedRecordings(createdBefore: launch, usingFallbackStore: false)
            #expect(recordings.deleted.isEmpty)
        }
    }

    /// A row whose result can't be decoded (a coding regression) may be a session with a recording:
    /// the repository can't vouch for the set, and says so.
    @Test func anUndecodableRowMakesTheSetUnknown() async throws {
        let container = try ModelContainer(for: HistoryModel.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repo = SwiftDataHistoryRepository(modelContainer: container, recordings: nil)
        try await repo.append(session("one.m4a"))
        try await repo.append(HistoryEntry(inputText: "q", result: .translate(ru: "r")))
        #expect(try await repo.referencedRecordings() == ["one.m4a"])

        let context = ModelContext(container)
        let broken = try HistoryModel(session("two.m4a"))
        broken.resultData = Data("not a result".utf8)
        context.insert(broken)
        try context.save()
        #expect(try await repo.referencedRecordings() == nil)
        #expect(try await repo.recent(limit: 10).count == 2)                    // the list still drops it
    }

    /// On disk: an orphan older than the cut-off goes, a newer one and a referenced one stay.
    @Test func theStoreKeepsFilesNewerThanTheCutOff() async throws {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appending(path: "SessionRecordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Whatever is already there is "kept" — the test only ever deletes its own files.
        let others = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        let tag = UUID().uuidString
        let orphan = "test-\(tag)-orphan.m4a", referenced = "test-\(tag)-referenced.m4a"
        for name in [orphan, referenced] { try Data("audio".utf8).write(to: dir.appending(path: name)) }
        defer { for name in [orphan, referenced] { try? FileManager.default.removeItem(at: dir.appending(path: name)) } }
        let store = SessionRecordingsPlayer()

        await store.sweep(keeping: others.union([referenced]), createdBefore: Date().addingTimeInterval(-60))
        #expect(store.exists(fileName: orphan))                                // created after the cut-off

        await store.sweep(keeping: others.union([referenced]), createdBefore: Date().addingTimeInterval(60))
        #expect(!store.exists(fileName: orphan))
        #expect(store.exists(fileName: referenced))
    }
}

/// History that can't vouch for its recordings: the read throws, or an entry couldn't be read (nil).
private struct UnsureHistory: HistoryRepository {
    let fails: Bool
    func append(_ entry: HistoryEntry) async throws {}
    func recent(limit: Int) async throws -> [HistoryEntry] { [] }
    func delete(id: HistoryEntry.ID) async throws {}
    func referencedRecordings() async throws -> Set<String>? {
        if fails { throw RepositoryError.persistenceFailed("read failed") }
        return nil
    }
}
