//
//  UserDefaultsDuplicateDismissalStore.swift
//  EnglishHelper — Data
//
//  Where the first 2.0 builds kept "not duplicates" — sets of phrase ids in UserDefaults. Read once by
//  `DuplicatesInteractor`, turned into links with the cards (`SwiftDataNotDuplicateMarks`), then cleared.
//

import Foundation
import Domain

public final class UserDefaultsDuplicateDismissalStore: DuplicateDismissalStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "flashcardsNotDuplicates"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func dismissed() async -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    public func clear() async {
        defaults.removeObject(forKey: key)
    }
}
