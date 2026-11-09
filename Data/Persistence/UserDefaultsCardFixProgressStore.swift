//
//  UserDefaultsCardFixProgressStore.swift
//  EnglishHelper — Data
//
//  Where the last "Fix cards" run of each scope stopped — one small JSON value per scope in UserDefaults.
//

import Foundation
import Domain

public final class UserDefaultsCardFixProgressStore: CardFixProgressStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The all-phrases scope keeps the key it had before scopes existed.
    private func key(_ scope: FixScope) -> String {
        scope == .all ? "flashcardsFixCheckpoint" : "flashcardsFixCheckpoint.\(scope.rawValue)"
    }

    public func load(_ scope: FixScope) async -> CardFixCheckpoint? {
        defaults.data(forKey: key(scope)).flatMap { try? JSONDecoder().decode(CardFixCheckpoint.self, from: $0) }
    }

    public func save(_ checkpoint: CardFixCheckpoint, for scope: FixScope) async {
        if let data = try? JSONEncoder().encode(checkpoint) { defaults.set(data, forKey: key(scope)) }
    }

    public func reset(_ scope: FixScope) async {
        defaults.removeObject(forKey: key(scope))
    }
}
