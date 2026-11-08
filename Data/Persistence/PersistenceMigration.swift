//
//  PersistenceMigration.swift
//  EnglishHelper — Data (SwiftData)
//
//  Versioned schema + migration plan for the on-disk store. The point is forward safety: when the
//  @Model shape changes, add a new VersionedSchema and a MigrationStage here so the store MIGRATES
//  instead of failing to open — a failed open would otherwise drop the user's saved study list and
//  history. With one version the plan is a no-op, but the scaffolding is in place.
//

import Foundation
import SwiftData

/// v1 — `ExpressionModel` + `HistoryModel`.
public enum AppSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] { [ExpressionModel.self, HistoryModel.self] }
}

/// v2 — adds `CachedTranslationModel` (the translation cache). Adding a new entity is additive, so the
/// V1→V2 stage is lightweight (SwiftData just creates the new table; existing data is untouched).
public enum AppSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [ExpressionModel.self, HistoryModel.self, CachedTranslationModel.self]
    }
}

/// v3 (2.0) — adds `ReviewCardModel` (flashcard spaced-repetition state). A new entity again, so the
/// V2→V3 stage is lightweight too: the saved expressions and history are untouched (every saved
/// expression starts out on the Caught list — no cards).
public enum AppSchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [ExpressionModel.self, HistoryModel.self, CachedTranslationModel.self, ReviewCardModel.self]
    }
}

/// v4 (2.0) — adds `ReviewLogModel` (every answer). Its own version, not folded into V3: a 2.0 build
/// already wrote V3 stores, and a store whose models match no version can't be opened at all
/// (`unknownDataStoreSchema` → the in-memory fallback). NEVER change a version's models once a build
/// has used it — add the next version (PersistenceMigrationTests opens a store of every version).
public enum AppSchemaV4: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [ExpressionModel.self, HistoryModel.self, CachedTranslationModel.self, ReviewCardModel.self,
         ReviewLogModel.self]
    }
}

/// Migration plan across schema versions. Append a new `AppSchemaVn` and a `MigrationStage`
/// (lightweight or custom) for every breaking change — never just bump the models.
public enum AppMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [AppSchemaV1.self, AppSchemaV2.self, AppSchemaV3.self, AppSchemaV4.self]
    }
    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: AppSchemaV1.self, toVersion: AppSchemaV2.self),
         .lightweight(fromVersion: AppSchemaV2.self, toVersion: AppSchemaV3.self),
         .lightweight(fromVersion: AppSchemaV3.self, toVersion: AppSchemaV4.self)]
    }
}
