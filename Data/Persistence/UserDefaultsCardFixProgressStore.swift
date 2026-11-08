//
//  UserDefaultsCardFixProgressStore.swift
//  EnglishHelper — Data
//
//  Where the last "Fix cards" run stopped — one small JSON value in UserDefaults.
//

import Foundation
import Domain

public final class UserDefaultsCardFixProgressStore: CardFixProgressStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "flashcardsFixCheckpoint"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() async -> CardFixCheckpoint? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(CardFixCheckpoint.self, from: $0) }
    }

    public func save(_ checkpoint: CardFixCheckpoint) async {
        if let data = try? JSONEncoder().encode(checkpoint) { defaults.set(data, forKey: key) }
    }

    public func reset() async {
        defaults.removeObject(forKey: key)
    }
}
