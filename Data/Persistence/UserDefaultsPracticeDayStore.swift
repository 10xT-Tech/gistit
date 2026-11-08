//
//  UserDefaultsPracticeDayStore.swift
//  EnglishHelper — Data
//
//  Today's practice set, as JSON in UserDefaults — one small value, rewritten when a day starts or
//  grows; no SwiftData schema change for it.
//

import Foundation
import Domain

public final class UserDefaultsPracticeDayStore: PracticeDayStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "flashcardsPracticeDay"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() async -> PracticeDay? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PracticeDay.self, from: $0) }
    }

    public func save(_ day: PracticeDay) async {
        if let data = try? JSONEncoder().encode(day) { defaults.set(data, forKey: key) }
    }
}
