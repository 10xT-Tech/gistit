//
//  HistoryEntry.swift
//  EnglishHelper — Domain
//

import Foundation

/// What kind of request the user made.
public enum RequestKind: String, Codable, Sendable, CaseIterable, Hashable {
    case howToSay
    case whatToSay
    case translate
    case photoTranslate
    case photoExplain
    case liveTranslation
}

/// The typed payload of a completed request. One case per `RequestKind`.
public enum RequestResult: Codable, Sendable, Equatable, Hashable {
    /// `howToSay` → three register-tagged variants of one thought.
    case howToSay([PhraseVariant])
    /// `whatToSay` → 3–10 register-tagged phrases useful in a described situation.
    case whatToSay([PhraseVariant])
    /// `translate` → pure Russian translation.
    case translate(ru: String)
    /// `photoTranslate` → pure Russian translation of OCR'd text.
    case photoTranslate(ru: String)
    /// `photoExplain` → what the photo shows + its local/cultural context (native language).
    /// Text only — the photo itself is never persisted.
    case photoExplain(title: String, details: String)
    /// `liveTranslation` → one online listening session: everything that was heard (studied
    /// language) + its live translation (native), plus the session recording for playback.
    /// `audioFileName` is a file in the recordings store (nil = no audio kept); `duration` seconds.
    case liveTranslation(original: String, ru: String, audioFileName: String?, duration: TimeInterval)

    /// The session recording this result keeps, if any.
    public var recordingFileName: String? {
        guard case .liveTranslation(_, _, let fileName?, _) = self else { return nil }
        return fileName
    }

    public var kind: RequestKind {
        switch self {
        case .howToSay: .howToSay
        case .whatToSay: .whatToSay
        case .translate: .translate
        case .photoTranslate: .photoTranslate
        case .photoExplain: .photoExplain
        case .liveTranslation: .liveTranslation
        }
    }
}

/// A log of every request the user made. Append-only.
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let kind: RequestKind
    /// The raw input that produced this entry (RU intent, EN text, or OCR text).
    public let inputText: String
    public let result: RequestResult
    public let createdAt: Date

    public init(id: UUID = UUID(), inputText: String, result: RequestResult, createdAt: Date = Date()) {
        self.id = id
        self.kind = result.kind        // kind always agrees with the result payload
        self.inputText = inputText
        self.result = result
        self.createdAt = createdAt
    }
}
