//
//  NaturalLanguageLemmatizer.swift
//  EnglishHelper — Data
//
//  `Lemmatizing` on Apple's NaturalLanguage: each word of a phrase becomes its dictionary form
//  ("jumping" → "jump", "I'm" → "I be"), so the duplicate check sees "jumping the gun" and "jump the
//  gun" as one phrase. A word the tagger has no lemma for stays as written — also when the language's
//  lemma assets aren't on the device yet: `prepare` asks the system for them before a scan. One
//  tagger per language, reused — a scan lemmatizes thousands of phrases.
//

import Foundation
import NaturalLanguage
import Domain

public final class NaturalLanguageLemmatizer: Lemmatizing, @unchecked Sendable {
    private let lock = NSLock()
    private var taggers: [NLLanguage: NLTagger] = [:]

    public init() {}

    public func prepare(language: String) async {
        guard let code = Self.languages[language] else { return }
        _ = try? await NLTagger.requestAssets(for: code, tagScheme: .lemma)
    }

    public func lemmatize(_ text: String, language: String) -> String {
        guard let code = Self.languages[language], !text.isEmpty else { return text }
        return lock.withLock {
            let tagger = taggers[code] ?? NLTagger(tagSchemes: [.lemma])
            taggers[code] = tagger
            tagger.string = text
            let range = text.startIndex..<text.endIndex
            tagger.setLanguage(code, range: range)
            var words: [String] = []
            tagger.enumerateTags(in: range, unit: .word, scheme: .lemma,
                                 options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, wordRange in
                let lemma = tag?.rawValue.lowercased() ?? ""
                words.append(lemma.isEmpty ? String(text[wordRange]) : lemma)
                return true
            }
            return words.isEmpty ? text : words.joined(separator: " ")
        }
    }

    private static let languages: [String: NLLanguage] = [
        "English": .english, "German": .german, "French": .french,
        "Spanish": .spanish, "Italian": .italian, "Russian": .russian,
    ]
}
