//
//  UserDefaultsDuplicateDismissalStore.swift
//  EnglishHelper — Data
//
//  Look-alike groups the user called "not duplicates" — their ids (the members' sorted ids) in
//  UserDefaults, so a scan doesn't offer them again.
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

    public func dismiss(_ groupID: String) async {
        var ids = defaults.stringArray(forKey: key) ?? []
        guard !ids.contains(groupID) else { return }
        ids.append(groupID)
        defaults.set(ids, forKey: key)
    }
}
