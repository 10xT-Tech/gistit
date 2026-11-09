//
//  PhraseKey.swift
//  EnglishHelper — Domain
//
//  What two phrases in the studied language are compared by when looking for duplicates: the same
//  words apart from letter case, accents, typographic apostrophes, a leading infinitive marker or
//  article ("to", "a", "der", "la"…), glosses in brackets, punctuation and spacing — and, with a
//  lemmatizer, word forms ("jumping the gun" = "jump the gun"). "to hit the roof" and "Hit the
//  roof!" share a key; "solid" (надёжный) and "solid" (твёрдый) too — whether they're one card is for
//  the model (and the user) to say.
//  A SLOT changes the expression, so it is never dropped — only its spellings are made one:
//  "someone" / "somebody" / "sb" / "smb" (also in brackets: "wind (someone) up"), "sth" / "smth" →
//  "something", "one's" / "sb's" → "someone's", "jdn" → "jemanden", "qqn" → "quelqu'un"…; and the
//  English "+ -ing" marker is "doing". "pick on sb" = "pick on someone", but "fuck about" ≠ "fuck
//  somebody about", "wind up" ≠ "wind sb up", "stop + -ing" ≠ "stop + to".
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
        let slots = Self.slots[language] ?? [:]
        var s = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        // Brackets: a slot in them ("(someone)") stays a slot; anything else is a gloss ("(future)").
        s = s.replacing(/\(([^)]*)\)|\[([^\]]*)\]/) { match in
            let inside = String(match.output.1 ?? match.output.2 ?? "")
                .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            return slots[inside].map { " \($0) " } ?? " "
        }
        if language == "English" { s = s.replacing(/\+\s*-?ing\b/, with: " doing ") }   // "finish + -ing"
        s = s.replacing(/[^\p{L}\p{N}']+/, with: " ")                                      // punctuation, "…", "/"
        var words = s.split(separator: " ").map(String.init)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
            .map { slots[$0] ?? $0 }
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

    /// The spellings of a "someone / something" slot → the one the key uses.
    static let slots: [String: [String: String]] = [
        "English": [
            "someone": "someone", "somebody": "someone", "smb": "someone", "sb": "someone", "smbd": "someone",
            "someone's": "someone's", "somebody's": "someone's", "smb's": "someone's", "sb's": "someone's",
            "one's": "someone's",
            "something": "something", "sth": "something", "smth": "something", "smt": "something",
        ],
        "German": [
            "jemand": "jemand", "jemanden": "jemanden", "jdn": "jemanden", "jemandem": "jemandem", "jdm": "jemandem",
            "jemandes": "jemandes", "jds": "jemandes", "etwas": "etwas", "etw": "etwas",
        ],
        "French": [
            "quelqu'un": "quelqu'un", "qqn": "quelqu'un", "qn": "quelqu'un",
            "qqch": "quelque chose", "qch": "quelque chose", "quelque chose": "quelque chose",
        ],
        "Spanish": ["alguien": "alguien", "algo": "algo", "alg": "algo"],
        "Italian": [
            "qualcuno": "qualcuno", "qn": "qualcuno", "qualcosa": "qualcosa", "qc": "qualcosa", "qcs": "qualcosa",
        ],
    ]
}
