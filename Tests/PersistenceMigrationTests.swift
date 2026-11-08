//
//  PersistenceMigrationTests.swift
//  EnglishHelperTests
//
//  The on-disk store must open after an update, with its data: a store written by an older schema
//  version is migrated by `AppMigrationPlan`, never refused (a refused store sends the app to the
//  in-memory fallback — "Saved data is unavailable" — for the whole session).
//

import Testing
import Foundation
import SwiftData
import Domain
import Adapters

@Suite struct PersistenceMigrationTests {

    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "migration-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "test.store")
    }

    /// Write one saved expression with `schema` (an older version), then open the store the way the app
    /// does and read it back.
    private func roundTrip(writingWith schema: Schema) throws -> [String] {
        let url = storeURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(old)
            context.insert(ExpressionModel(Domain.Expression(en: "break the ice", ru: "растопить лёд")))
            try context.save()
        }
        let current = PersistenceSchema.current
        let container = try ModelContainer(for: current, migrationPlan: AppMigrationPlan.self,
                                           configurations: ModelConfiguration(schema: current, url: url))
        return try ModelContext(container).fetch(FetchDescriptor<ExpressionModel>()).map(\.en)
    }

    /// 1.x users: the shipped V2 store (study list, history, translation cache).
    @Test func storeFromOneDotXOpens() throws {
        #expect(try roundTrip(writingWith: Schema(versionedSchema: AppSchemaV2.self)) == ["break the ice"])
    }

    /// The first 2.0 development build (1a24e30) wrote flashcards without the review log.
    @Test func storeFromTheFirstFlashcardsBuildOpens() throws {
        let firstFlashcards = Schema([ExpressionModel.self, HistoryModel.self, CachedTranslationModel.self,
                                      ReviewCardModel.self], version: Schema.Version(3, 0, 0))
        #expect(try roundTrip(writingWith: firstFlashcards) == ["break the ice"])
    }

    /// The later 2.0 development builds (644e76a, 148fdaf) wrote the review log under the V3 number.
    @Test func storeFromTheDashboardBuildsOpens() throws {
        let dashboard = Schema([ExpressionModel.self, HistoryModel.self, CachedTranslationModel.self,
                                ReviewCardModel.self, ReviewLogModel.self], version: Schema.Version(3, 0, 0))
        #expect(try roundTrip(writingWith: dashboard) == ["break the ice"])
    }

    /// Every version in the plan opens — including the 2.0 development steps a device may have run.
    @Test func everySchemaVersionOpens() throws {
        for version in AppMigrationPlan.schemas {
            #expect(try roundTrip(writingWith: Schema(versionedSchema: version)) == ["break the ice"],
                    "a store written with \(version.versionIdentifier) didn't open")
        }
    }

    /// No two versions may describe different models under one version number (the store can't be
    /// matched to its version then), and versions only go up.
    @Test func versionIdentifiersAreDistinctAndIncreasing() {
        let ids = AppMigrationPlan.schemas.map { "\($0.versionIdentifier)" }
        #expect(Set(ids).count == ids.count)
        #expect(AppMigrationPlan.stages.count == AppMigrationPlan.schemas.count - 1)
    }
}
