//
//  PhraseKey.swift
//  EnglishHelper — Domain
//
//  What two phrases in the studied language are compared by when looking for duplicates: the same
//  words apart from letter case, accents, typographic apostrophes, a leading infinitive marker or
//  article ("to", "a", "der", "la"…), placeholders ("someone", "sth", "jemanden"…), parts in brackets,
//  "+ -ing" markers, punctuation and spacing — and, with a lemmatizer, word forms ("jumping the
//  gun" = "jump the gun"). "to hit the roof" and "Hit the roof!" share a key; "solid" (надёжный) and
//  "solid" (твёрдый) too — whether they're one card is for the model (and the user) to say.
//

import Foundation

/// Reduces a phrase to its dictionary words (lemmas), word by word. Backed by the platform's
/// language tools in the app; identity where none is available.
public protocol Lemmatizing: Sendable {
    /// Make the language's lemmas available (the platform may have to download them) — before a scan.
    func prepare(language: String) async
    /// `text` (already lower case, words separated by single spaces) with each word replaced by its
    /// lemma. `language` is a prompt name ("English", "German"…).
    func lemmatize(_ text: String, language: String) -> String
}

/// No lemmas: the key compares word forms as written (tests, previews, the stub boot).
public struct NoLemmatizer: Lemmatizing {
    public init() {}
    public func prepare(language: String) async {}
    public func lemmatize(_ text: String, language: String) -> String { text }
}

public enum PhraseKey {
    /// The comparison key of `text` in `language` (a prompt name: "English", "German"…).
    public static func make(_ text: String, language: String, lemmatizer: any Lemmatizing = NoLemmatizer()) -> String {
        var s = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        s = s.replacing(/\([^)]*\)|\[[^\]]*\]/, with: " ")                  // "(someone)", "[sth]"
        s = s.replacing(/\+\s*-?ing\b/, with: " ")                          // "finish + -ing"
        for slot in Self.multiwordPlaceholders[language] ?? [] { s = s.replacingOccurrences(of: slot, with: " ") }
        s = s.replacing(/[^\p{L}\p{N}']+/, with: " ")                        // punctuation, "…", "/"
        var words = s.split(separator: " ").map(String.init)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
        let placeholders = Self.placeholders[language] ?? []
        words.removeAll { placeholders.contains($0) }
        if let first = words.first {
            if words.count > 1, (Self.leading[language] ?? []).contains(first) {
                words.removeFirst()
            } else if let elided = Self.elided[language]?.first(where: { first.hasPrefix($0) && first.count > $0.count }) {
                words[0] = String(first.dropFirst(elided.count))           // "l'arbre" → "arbre"
            }
        }
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return lemmatizer.lemmatize(joined, language: language)
            .split(separator: " ").joined(separator: " ")
    }

    /// Infinitive markers and articles a vocabulary list puts before a word.
    static let leading: [String: Set<String>] = [
        "English": ["to", "a", "an", "the"],
        "German": ["der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "zu", "sich"],
        "French": ["le", "la", "les", "un", "une", "des", "se"],
        "Spanish": ["el", "la", "los", "las", "un", "una", "unos", "unas"],
        "Italian": ["il", "lo", "la", "i", "gli", "le", "un", "uno", "una"],
    ]

    /// Articles and pronouns written onto the next word with an apostrophe.
    static let elided: [String: [String]] = [
        "French": ["l'", "s'", "d'"],
        "Italian": ["l'", "un'"],
    ]

    /// Slots written in more than one word, removed before the words are split.
    static let multiwordPlaceholders: [String: [String]] = [
        "French": ["quelque chose"],
    ]

    /// "Someone / something" slots of a phrase.
    static let placeholders: [String: Set<String>] = [
        "English": ["someone", "somebody", "something", "someone's", "somebody's", "one's", "smb", "smth", "sth", "sb", "smb's", "sb's"],
        "German": ["jemand", "jemanden", "jemandem", "jemandes", "etwas", "jdn", "jdm", "jds", "etw"],
        "French": ["quelqu'un", "qqn", "qqch", "qn", "qch"],
        "Spanish": ["alguien", "algo", "alg"],
        "Italian": ["qualcuno", "qualcosa", "qc", "qn", "qcs"],
    ]
}
