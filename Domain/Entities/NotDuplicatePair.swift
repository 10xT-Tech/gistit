//
//  NotDuplicatePair.swift
//  EnglishHelper — Domain
//
//  Two phrases the user said aren't duplicates ("Don't merge" in Find duplicates) — a link between
//  the two cards, kept with them (`NotDuplicateMarking`), so the next search doesn't offer them again
//  (unless it's a full re-check). The pair is unordered: (a, b) == (b, a).
//

import Foundation

public struct NotDuplicatePair: Hashable, Sendable, Codable {
    public let first: UUID
    public let second: UUID

    public init(_ a: UUID, _ b: UUID) {
        if a.uuidString <= b.uuidString {
            first = a
            second = b
        } else {
            first = b
            second = a
        }
    }

    public func contains(_ id: UUID) -> Bool { first == id || second == id }

    /// The other phrase of the pair, if `id` is one of them.
    public func other(than id: UUID) -> UUID? {
        first == id ? second : second == id ? first : nil
    }

    /// Every pair among `ids`.
    public static func all(among ids: [UUID]) -> Set<NotDuplicatePair> {
        var pairs = Set<NotDuplicatePair>()
        for (index, a) in ids.enumerated() {
            for b in ids.dropFirst(index + 1) where a != b { pairs.insert(NotDuplicatePair(a, b)) }
        }
        return pairs
    }
}

/// The "not duplicates" links between cards.
public protocol NotDuplicateMarking: Sendable {
    func pairs() async throws -> Set<NotDuplicatePair>
    func mark(_ pairs: Set<NotDuplicatePair>) async throws
    /// Drop every link of these phrases (they were merged away).
    func unmark(involving ids: Set<UUID>) async throws
}

/// In-memory default (tests, previews, the stub boot).
public actor InMemoryNotDuplicateMarks: NotDuplicateMarking {
    private var stored: Set<NotDuplicatePair>
    public init(_ pairs: Set<NotDuplicatePair> = []) { stored = pairs }
    public func pairs() async throws -> Set<NotDuplicatePair> { stored }
    public func mark(_ pairs: Set<NotDuplicatePair>) async throws { stored.formUnion(pairs) }
    public func unmark(involving ids: Set<UUID>) async throws {
        stored = stored.filter { !ids.contains($0.first) && !ids.contains($0.second) }
    }
}
