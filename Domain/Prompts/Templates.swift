//
//  Templates.swift
//  EnglishHelper — Domain
//
//  v1 prompt templates. Each owns its system prompt, output schema, and typed decoder.
//  All string fields are plain text ONLY (no markdown / emoji / decorative symbols) — asked for by
//  the system prompts and enforced by `PlainText.clean` in every decoder. Schemas are sent as
//  structured-output formats: every object sets `additionalProperties: false`, and array-count
//  limits live in the decoders (structured outputs don't support complex array constraints).
//

import Foundation

// MARK: - Shared output payloads

/// `{ "variants": [ { en, register, context_ru } ] }`
public struct HowToSayResult: Codable, Sendable, Equatable {
    public let variants: [PhraseVariant]
}

/// `{ studied, native }` — a faithful rendering of the input in BOTH the studied language (the
/// card headline + TTS) and the native language (the understanding line). "Get it" / Translate.
/// One translation of the input into the native language, with the context/sense it fits.
public struct TranslationVariant: Codable, Sendable, Equatable {
    /// The translation in the native language (shown in the main text colour).
    public let text: String
    /// A short note on when/in what sense this translation applies (shown dimmed under the text).
    /// Empty when there is only a single translation (an unambiguous word or a longer phrase).
    public let context: String
    public init(text: String, context: String) {
        self.text = text
        self.context = context
    }
}

public struct Understanding: Codable, Sendable, Equatable {
    /// The input rendered in the STUDIED language (headline + spoken).
    public let studied: String
    /// 1–5 translations into the NATIVE language. MORE THAN ONE only when the source genuinely has
    /// different context/sense-dependent translations (e.g. a single word with several meanings);
    /// an unambiguous word or a longer phrase yields exactly one.
    public let variants: [TranslationVariant]
    public init(studied: String, variants: [TranslationVariant]) {
        self.studied = studied
        self.variants = variants
    }
}

/// `{ studied, meaning, register, context, analogy }` — a learner-facing explanation of an
/// expression. `studied` is the expression in the STUDIED language (headline + TTS); the rest are
/// written in the user's NATIVE language (not a translation).
public struct ExpressionExplanation: Codable, Sendable, Equatable {
    /// The expression rendered in the STUDIED language (headline + spoken).
    public let studied: String
    /// What the expression actually means / what is implied.
    public let meaning: String
    /// Tone of voice + how formal, casual, slangy, rude or offensive it is, and who says it to whom.
    public let register: String
    /// How it lands in the studied-language culture — when and where it's used.
    public let context: String
    /// A comparison to an equivalent in the learner's own (native) language/culture.
    public let analogy: String

    public init(studied: String, meaning: String, register: String, context: String, analogy: String) {
        self.studied = studied
        self.meaning = meaning
        self.register = register
        self.context = context
        self.analogy = analogy
    }
}

/// `{ title, details }` — a learner-facing explanation of WHAT a photo shows and its local/cultural
/// context (a landmark, a road sign, a product, …), written in the NATIVE language. Used by the
/// "See it" / Explain mode — the photo analogue of Get-it/Explain.
public struct SceneExplanation: Codable, Sendable, Equatable {
    /// A short name / headline for what the photo shows.
    public let title: String
    /// The explanation: what it is, its history / cultural / local context, any local rules or
    /// peculiarities, and how they differ from the learner's own environment. In the native language.
    public let details: String

    public init(title: String, details: String) {
        self.title = title
        self.details = details
    }
}

/// `{ "ru", "example", "synonyms": [..] }`
public struct CardEnrichment: Codable, Sendable, Equatable {
    public let ru: String
    public let example: String
    public let synonyms: [String]
}

/// Input for `enrichCard`: an English expression, optionally with a known Russian gloss.
public struct EnrichInput: Sendable, Equatable {
    public let en: String
    public let ru: String?
    public init(en: String, ru: String? = nil) {
        self.en = en
        self.ru = ru
    }
}

// MARK: - Plain-text rule (shared)

private let plainTextRule = """
All string values must be PLAIN TEXT only: no markdown, bold, italic, emoji, quotes, \
or decorative symbols inside any field.
"""

// MARK: - howToSay

/// RU intent → exactly 3 English variants in the chosen tone/register.
public struct HowToSayTemplate: PromptTemplate {
    public typealias Input = String
    public typealias Output = HowToSayResult

    public let id = "howToSay"
    public let tone: Register
    public let studiedLanguage: String   // the language being learned — the variants are in THIS language
    public let nativeLanguage: String    // the learner's own language — the notes are in THIS language
    public let tier: ModelTier
    public init(tone: Register = .casual, studiedLanguage: String = "English", nativeLanguage: String = "Russian",
                tier: ModelTier = .standard) {
        self.tone = tone
        self.studiedLanguage = studiedLanguage
        self.nativeLanguage = nativeLanguage
        self.tier = tier
    }

    /// "Say it" phrase generation routes to the user-selected model (default: the STANDARD model, Sonnet).
    public var modelTier: ModelTier { tier }

    public var systemPrompt: String {
        """
        You help a \(nativeLanguage) speaker who is learning \(studiedLanguage) say something naturally
        in \(studiedLanguage). The input may be written in \(nativeLanguage), in \(studiedLanguage), or
        in ANY other language — detect it and understand the intended meaning (interpret the intent as
        if expressed in \(nativeLanguage) first).
        Then return EXACTLY THREE \(studiedLanguage) variants of that intent, all in a \(toneHint) tone,
        each a DIFFERENT natural phrasing.
        Each variant has: "en" (the \(studiedLanguage) phrasing), "register" (use "\(toneRegister)"),
        and "context_ru" (one short note IN \(nativeLanguage) on when/why to use it).
        \(plainTextRule)
        """
    }

    private var toneHint: String {
        switch tone {
        case .formal: "formal and polite (work, strangers, writing)"
        case .neutral, .casual: "everyday conversational (friends, colleagues)"
        case .slang: "informal, slangy (close friends)"
        }
    }

    private var toneRegister: String {
        tone == .neutral ? "casual" : tone.rawValue   // the design styles 3 tiers
    }

    public var outputJSONSchema: String {
        """
        {"type":"object","properties":{"variants":{"type":"array",
        "items":{"type":"object","properties":{"en":{"type":"string"},
        "register":{"enum":["formal","neutral","casual","slang"]},
        "context_ru":{"type":"string"}},"required":["en","register","context_ru"],
        "additionalProperties":false}}},
        "required":["variants"],"additionalProperties":false}
        """
    }

    public func userMessage(for input: String) -> String { input }

    public func decode(_ rawJSON: String) throws -> HowToSayResult {
        let result = try decodeJSON(HowToSayResult.self, from: rawJSON)
        guard result.variants.count == 3 else {
            throw LLMError.invalidOutput("howToSay expects exactly 3 variants, got \(result.variants.count)")
        }
        let cleaned = result.variants.map {
            PhraseVariant(id: $0.id, en: PlainText.clean($0.en), register: $0.register,
                          contextRU: PlainText.clean($0.contextRU))
        }
        return HowToSayResult(variants: cleaned)
    }
}

// MARK: - whatToSay

/// A SITUATION description → the 3–10 most useful phrases to say in that situation, in the studied
/// language and chosen tone, each with a native-language note. Same card shape as `howToSay`
/// (`HowToSayResult`), but the model decides HOW MANY phrases (by relevance), not a fixed three.
public struct WhatToSayTemplate: PromptTemplate {
    public typealias Input = String
    public typealias Output = HowToSayResult

    public let id = "whatToSay"
    public let tone: Register
    public let studiedLanguage: String   // the phrases are produced in THIS language
    public let nativeLanguage: String    // the notes are written in THIS language
    public let tier: ModelTier
    public init(tone: Register = .casual, studiedLanguage: String = "English", nativeLanguage: String = "Russian",
                tier: ModelTier = .standard) {
        self.tone = tone
        self.studiedLanguage = studiedLanguage
        self.nativeLanguage = nativeLanguage
        self.tier = tier
    }

    /// "Say it" phrase generation routes to the user-selected model (default: the STANDARD model, Sonnet).
    public var modelTier: ModelTier { tier }

    public var systemPrompt: String {
        """
        You help a \(nativeLanguage) speaker who is learning \(studiedLanguage) handle a real-life
        SITUATION in \(studiedLanguage). The input is a short description of a situation (e.g. "a
        doctor's appointment", "booking a car service", "checking in at a hotel"), written in
        \(nativeLanguage), in \(studiedLanguage), or in ANY other language — detect it and understand
        the situation (do NOT translate the description; it is not the phrase to say).
        Return the phrases that would actually be MOST USEFUL to say in that situation, in
        \(studiedLanguage), all in a \(toneHint) tone. Decide how many to give by genuine usefulness:
        AT LEAST 3 and AT MOST 10 — no filler, no near-duplicates. Order them from most to least
        likely to be needed.
        Each item has: "en" (the \(studiedLanguage) phrase), "register" (use "\(toneRegister)"),
        and "context_ru" (one short note IN \(nativeLanguage) on when/why to use this phrase here).
        \(plainTextRule)
        """
    }

    private var toneHint: String {
        switch tone {
        case .formal: "formal and polite (work, strangers, writing)"
        case .neutral, .casual: "everyday conversational (friends, colleagues)"
        case .slang: "informal, slangy (close friends)"
        }
    }

    private var toneRegister: String {
        tone == .neutral ? "casual" : tone.rawValue
    }

    public var outputJSONSchema: String {
        """
        {"type":"object","properties":{"variants":{"type":"array",
        "items":{"type":"object","properties":{"en":{"type":"string"},
        "register":{"enum":["formal","neutral","casual","slang"]},
        "context_ru":{"type":"string"}},"required":["en","register","context_ru"],
        "additionalProperties":false}}},
        "required":["variants"],"additionalProperties":false}
        """
    }

    public func userMessage(for input: String) -> String { input }

    public func decode(_ rawJSON: String) throws -> HowToSayResult {
        let result = try decodeJSON(HowToSayResult.self, from: rawJSON)
        // The prompt ASKS for 3–10 (a quality nudge for the model). The decoder is deliberately
        // lenient on the low end: if the model returns just 1–2 genuinely-useful phrases, show them
        // rather than hard-failing the whole request — only an EMPTY set is an error. The 10-max is
        // still enforced here in case the model overshoots. Sanitize to plain text like every template.
        let clamped = result.variants.prefix(10).map {
            PhraseVariant(id: $0.id, en: PlainText.clean($0.en), register: $0.register,
                          contextRU: PlainText.clean($0.contextRU))
        }
        guard !clamped.isEmpty else {
            throw LLMError.invalidOutput("whatToSay returned no phrases")
        }
        return HowToSayResult(variants: clamped)
    }
}

// MARK: - explainExpression ("Понять"/Get, Explain mode)

/// A word, phrase, OR a longer multi-line passage → a structured explanation in the learner's NATIVE
/// language: what it means, its tone/register, how it lands in an English-speaking culture, and an
/// analogy to the learner's own language. For understanding nuance, NOT translating. The input is
/// always explained as ONE coherent whole — a passage is never collapsed down to a single word.
///
/// Input carries the text plus an OPTIONAL photo: when explaining a block recognized from a photo
/// (the "See it" screen), the image is attached so the explanation reflects where the text actually
/// appears (a sign, menu, screenshot, post, …).
public struct ExplainInput: Sendable, Equatable {
    public let text: String
    public let image: Data?
    /// Other phrasings the expression is being chosen AMONG (the sibling "Say it" variants). When
    /// present, the explanation contrasts THIS phrasing against them — why this one, not those.
    public let alternatives: [String]
    public init(text: String, image: Data? = nil, alternatives: [String] = []) {
        self.text = text
        self.image = image
        self.alternatives = alternatives
    }
}

public struct ExplainExpressionTemplate: PromptTemplate {
    public typealias Input = ExplainInput
    public typealias Output = ExpressionExplanation

    public let id = "explainExpression"
    public let studiedLanguage: String   // the language being learned (the "studied" headline)
    public let nativeLanguage: String    // the explanation is written in THIS language
    public let tier: ModelTier
    public init(studiedLanguage: String = "English", nativeLanguage: String = "Russian",
                tier: ModelTier = .standard) {
        self.studiedLanguage = studiedLanguage
        self.nativeLanguage = nativeLanguage
        self.tier = tier
    }

    /// Explanation routes to the user-selected explain model (default: the STANDARD model, Sonnet).
    public var modelTier: ModelTier { tier }

    public var systemPrompt: String {
        """
        A \(nativeLanguage) speaker who is learning \(studiedLanguage) wants to understand some input.
        The input may be a single word, a phrase, or a longer MULTI-LINE passage (e.g. several lines
        read from a photo). Detect the input language (it may be in \(studiedLanguage), in
        \(nativeLanguage), or in any other language). If a photo is attached, it shows where this text
        appears (a sign, menu, screen, post, …) — use that visual context so the explanation fits that
        specific situation.

        Explain ALL of the input as ONE coherent whole. NEVER reduce a multi-line passage to a single
        word or phrase and explain only that — cover everything you were given:
        - a single word or short phrase → explain that expression (its real sense and connotations);
        - a longer / multi-line passage → explain the passage as a whole: its overall meaning, its
          overall tone, where such text appears, and a familiar equivalent — do not pick out just one
          line.

        LANGUAGE RULES (critical):
        - The "studied" field is in \(studiedLanguage) (the input itself).
        - EVERY other field — "meaning", "register", "context", "analogy" — MUST be written ENTIRELY in
          \(nativeLanguage). Even when a field describes the \(studiedLanguage) text or
          \(studiedLanguage)-speaking culture, write that description IN \(nativeLanguage). Never write
          meaning, register, or context in \(studiedLanguage).

        Return (explain the nuance — do NOT just translate):
        - "studied": the WHOLE input in \(studiedLanguage), preserving every line (if it is already in
          \(studiedLanguage), copy it verbatim; never shorten it to one expression).
        - "meaning" (in \(nativeLanguage)): what it actually means and what is implied — the real sense
          of the whole thing.
        - "register" (in \(nativeLanguage)): the tone of voice and how formal, neutral, casual, slangy,
          rude, or offensive it is, and who would say it to whom.
        - "context" (in \(nativeLanguage)): what it signals in \(studiedLanguage)-speaking culture —
          when and where it is used.
        - "analogy" (in \(nativeLanguage)): a comparison to an equivalent expression or situation in
          \(nativeLanguage)-speaking culture, so the learner can map it onto something familiar.

        If the input is a single neutral word, still describe its connotations and typical usage.

        If the user message lists ALTERNATIVE phrasings (under "Other phrasings…"), the user is choosing
        between them: make "meaning" and especially "register" explain WHY this exact phrasing rather
        than those — the distinguishing nuance (tense/aspect, formality, connotation, when each fits).
        \(plainTextRule)
        """
    }

    public var outputJSONSchema: String {
        """
        {"type":"object","properties":{"studied":{"type":"string"},"meaning":{"type":"string"},
        "register":{"type":"string"},"context":{"type":"string"},"analogy":{"type":"string"}},
        "required":["studied","meaning","register","context","analogy"],"additionalProperties":false}
        """
    }

    public func userMessage(for input: ExplainInput) -> String {
        guard !input.alternatives.isEmpty else { return input.text }
        let others = input.alternatives.map { "- \($0)" }.joined(separator: "\n")
        return """
        \(input.text)

        Other phrasings the user is choosing between (contrast this one against them):
        \(others)
        """
    }

    public func image(for input: ExplainInput) -> Data? { input.image }

    public func decode(_ rawJSON: String) throws -> ExpressionExplanation {
        let raw = try decodeJSON(ExpressionExplanation.self, from: rawJSON)
        return ExpressionExplanation(
            studied: PlainText.clean(raw.studied),
            meaning: PlainText.clean(raw.meaning),
            register: PlainText.clean(raw.register),
            context: PlainText.clean(raw.context),
            analogy: PlainText.clean(raw.analogy)
        )
    }
}

// MARK: - understand ("Понять"/Get, Translate mode — faithful, into studied + native)

/// Faithful translation of input (ANY language) into BOTH the studied language (headline + TTS) and
/// the native language (understanding line). No composing, no tone — pure translation, source
/// auto-detected. Each rendering is translated from the ORIGINAL (never chained); when the input is
/// already in a target language, that field is the input verbatim.
public struct UnderstandTemplate: PromptTemplate {
    public typealias Input = String
    public typealias Output = Understanding

    public let id = "understand"
    public let studiedLanguage: String
    public let nativeLanguage: String
    public let tier: ModelTier
    public init(studiedLanguage: String = "English", nativeLanguage: String = "Russian",
                tier: ModelTier = .fast) {
        self.studiedLanguage = studiedLanguage
        self.nativeLanguage = nativeLanguage
        self.tier = tier
    }

    /// Plain translation routes to the user-selected translate model (default: the FAST model, Haiku).
    public var modelTier: ModelTier { tier }

    public var systemPrompt: String {
        """
        The user wants to understand some text. It may be in \(studiedLanguage), in \(nativeLanguage),
        or in ANY other language — detect the source language automatically. Stay FAITHFUL to the exact
        meaning and register; do NOT change the register or add commentary.
        Return:
        - "studied": the text in \(studiedLanguage) (if already in \(studiedLanguage), copy it verbatim).
        - "variants": the translation(s) into \(nativeLanguage). Return MORE THAN ONE only when the
          source has genuinely DISTINCT meanings or senses that translate differently depending on
          context — judged by MEANING, not by length. This applies equally to a single word (e.g.
          "bank" = a financial institution OR a riverbank) AND to a multi-word expression or idiom
          (e.g. "night and day" = the two times of day taken literally, vs. its idiomatic senses
          "completely different" or "around the clock"): a phrase is NOT automatically single-sense.
          When the text has just one faithful meaning, return EXACTLY ONE variant. NEVER pad with
          near-synonyms, word-order swaps, or stylistic rewordings. Up to 5 maximum, ordered most
          common first.
          Each variant is an object:
            * "text": the translation in \(nativeLanguage).
            * "context": a SHORT note in \(nativeLanguage) saying in which sense/context this translation
              applies, so the user can pick the right one. Set "context" to "" (empty) when there is
              only ONE variant.
        \(plainTextRule)
        """
    }

    public var outputJSONSchema: String {
        #"{"type":"object","properties":{"studied":{"type":"string"},"variants":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"},"context":{"type":"string"}},"required":["text","context"],"additionalProperties":false}}},"required":["studied","variants"],"additionalProperties":false}"#
    }

    public func userMessage(for input: String) -> String { input }

    public func decode(_ rawJSON: String) throws -> Understanding {
        let raw = try decodeJSON(Understanding.self, from: rawJSON)
        let variants = raw.variants
            .map { TranslationVariant(text: PlainText.clean($0.text), context: PlainText.clean($0.context)) }
            .filter { !$0.text.isEmpty }
            .prefix(5)
        guard !variants.isEmpty else { throw LLMError.invalidOutput("understand: no translation") }
        return Understanding(studied: PlainText.clean(raw.studied), variants: Array(variants))
    }
}

// MARK: - photoBlocks (multimodal: image → blocks of en + ru)

/// `{ "blocks": [ { en, ru } ] }` — the model decides how many blocks.
public struct PhotoBlocksResult: Codable, Sendable, Equatable {
    public let blocks: [TranslatedBlock]
}

/// Image → blocks of connected English text, each with a Russian translation. The LLM does the
/// recognition AND translation (replaces local OCR).
public struct PhotoBlocksTemplate: PromptTemplate {
    public typealias Input = RecognizableImage
    public typealias Output = PhotoBlocksResult

    public let id = "photoBlocks"
    public let studiedLanguage: String   // each block is rendered in THIS language as "en" (headline + TTS)
    public let nativeLanguage: String    // ...and in THIS language as "ru" (understanding line)
    public init(studiedLanguage: String = "English", nativeLanguage: String = "Russian") {
        self.studiedLanguage = studiedLanguage
        self.nativeLanguage = nativeLanguage
    }

    // A photo can contain a LOT of text (a full menu, a page) — each block emits en + ru, so the
    // response is far larger than the short text tasks. 2048 truncates it mid-JSON; give it room.
    public var maxOutputTokens: Int { 16384 }
    // Vision OCR + translation of dense text: lean toward accuracy/headroom over raw speed.
    public var prefersFastResponse: Bool { false }

    public var systemPrompt: String {
        """
        You read text from a photo. The text may be in ANY language. Group it into BLOCKS of connected
        meaning — decide how many blocks yourself (e.g. a sign, a paragraph, one menu item) and detect
        each block's language. For each block return:
        - "en": the block rendered in \(studiedLanguage) (if the block is already in \(studiedLanguage),
          copy it verbatim).
        - "ru": the block rendered in \(nativeLanguage) (if the block is already in \(nativeLanguage),
          copy it verbatim).
        Translate each rendering from the ORIGINAL block text (do not chain translations). Ignore
        decorative noise, logos, and fragments that are only numbers or symbols; if there is no
        readable text, return an empty "blocks" array. \(plainTextRule)
        """
    }

    public var outputJSONSchema: String {
        """
        {"type":"object","properties":{"blocks":{"type":"array","items":{"type":"object",
        "properties":{"en":{"type":"string"},"ru":{"type":"string"}},"required":["en","ru"],
        "additionalProperties":false}}},
        "required":["blocks"],"additionalProperties":false}
        """
    }

    public func userMessage(for input: RecognizableImage) -> String {
        "Read the text blocks from the image; render each in \(studiedLanguage) as \"en\" and in \(nativeLanguage) as \"ru\"."
    }

    public func image(for input: RecognizableImage) -> Data? { input.data }

    public func decode(_ rawJSON: String) throws -> PhotoBlocksResult {
        let raw = try decodeJSON(PhotoBlocksResult.self, from: rawJSON)
        let cleaned = raw.blocks
            .map { TranslatedBlock(en: PlainText.clean($0.en), ru: PlainText.clean($0.ru)) }
            .filter { !$0.en.isEmpty }
        return PhotoBlocksResult(blocks: cleaned)
    }
}

// MARK: - photoExplain (multimodal: image → cultural/local explanation of what it shows)

/// Image → an explanation of WHAT the photo shows in the context of the STUDIED-language place/country
/// (a landmark + its history, a rental-car brand + its quirks, a road sign + the local rule behind it,
/// …), written in the NATIVE language. The "See it" analogue of Get-it/Explain. Not OCR — it explains
/// the scene/object, helping the learner understand the local/cultural context.
public struct PhotoExplainTemplate: PromptTemplate {
    public typealias Input = RecognizableImage
    public typealias Output = SceneExplanation

    public let id = "photoExplain"
    public let studiedLanguage: String   // the place/country whose context to explain (the studied env)
    public let nativeLanguage: String    // the explanation is WRITTEN in this language
    public init(studiedLanguage: String = "English", nativeLanguage: String = "Russian") {
        self.studiedLanguage = studiedLanguage
        self.nativeLanguage = nativeLanguage
    }

    // Vision + a thoughtful multi-paragraph explanation: give it room and the balanced (not fast) profile.
    public var maxOutputTokens: Int { 8192 }
    public var prefersFastResponse: Bool { false }

    public var systemPrompt: String {
        """
        A \(nativeLanguage) speaker who is learning \(studiedLanguage) — and is likely travelling in a
        \(studiedLanguage)-speaking place — took or picked this photo and wants to understand WHAT it
        shows and its LOCAL / CULTURAL context. Help them make sense of it in the \(studiedLanguage)-
        speaking environment. This is NOT translation and NOT OCR — explain the scene / object / place.

        Identify what is in the photo and explain it for someone unfamiliar with the local context:
        - a landmark or place → what it is, briefly its history and why it matters locally;
        - a product, brand, shop, or rental (e.g. a car-rental sign) → what the company / thing is and
          its notable local specifics;
        - a road sign, notice, or rule → what it means, the LOCAL rule behind it, and how it differs
          from what a \(nativeLanguage) speaker is used to;
        - food, a menu item, or an everyday object → what it is and its local significance.
        Focus on cultural / local context and on differences from the learner's own country. If the
        photo is unclear or there is nothing meaningful to explain, say so plainly in "details".

        Write BOTH fields ENTIRELY in \(nativeLanguage):
        - "title": a short name / headline for what the photo shows.
        - "details": the explanation (a few short paragraphs) — what it is, its local / cultural context,
          and any peculiarities or differences worth knowing.
        \(plainTextRule)
        """
    }

    public var outputJSONSchema: String {
        #"{"type":"object","properties":{"title":{"type":"string"},"details":{"type":"string"}},"required":["title","details"],"additionalProperties":false}"#
    }

    public func userMessage(for input: RecognizableImage) -> String {
        "Explain what this photo shows and its local/cultural context."
    }

    public func image(for input: RecognizableImage) -> Data? { input.data }

    public func decode(_ rawJSON: String) throws -> SceneExplanation {
        let raw = try decodeJSON(SceneExplanation.self, from: rawJSON)
        return SceneExplanation(title: PlainText.clean(raw.title), details: PlainText.clean(raw.details))
    }
}

// MARK: - enrichCard

/// `{ en (+ optional ru) }` → `{ ru, example, synonyms }` for a study-list card.
public struct EnrichCardTemplate: PromptTemplate {
    public typealias Input = EnrichInput
    public typealias Output = CardEnrichment

    public let id = "enrichCard"
    public init() {}

    public var systemPrompt: String {
        """
        Enrich an English expression for a study card. Return:
        - "ru": a concise natural Russian translation.
        - "example": ONE natural English sentence that uses the expression.
        - "synonyms": 2 to 3 English near-equivalents. Use fewer if none fit; do NOT invent bad ones.
        \(plainTextRule)
        """
    }

    public var outputJSONSchema: String {
        """
        {"type":"object","properties":{"ru":{"type":"string"},"example":{"type":"string"},
        "synonyms":{"type":"array","items":{"type":"string"}}},
        "required":["ru","example","synonyms"],"additionalProperties":false}
        """
    }

    public func userMessage(for input: EnrichInput) -> String {
        if let ru = input.ru, !ru.isEmpty {
            return "expression: \(input.en)\nknown_ru: \(ru)"
        }
        return "expression: \(input.en)"
    }

    public func decode(_ rawJSON: String) throws -> CardEnrichment {
        let raw = try decodeJSON(CardEnrichment.self, from: rawJSON)
        // Enforce the contract regardless of what the model returned:
        // plain text only, and 0–3 non-empty synonyms.
        let synonyms = raw.synonyms
            .map(PlainText.clean)
            .filter { !$0.isEmpty }
            .prefix(3)
        return CardEnrichment(
            ru: PlainText.clean(raw.ru),
            example: PlainText.clean(raw.example),
            synonyms: Array(synonyms)
        )
    }
}

// MARK: - healthCheck (connection probe)

/// Minimal probe used by the Settings live health check — the cheapest possible round-trip.
public struct HealthCheckTemplate: PromptTemplate {
    public typealias Input = Void
    public typealias Output = Bool

    public let id = "healthCheck"
    /// Which model this ping checks — lets Settings probe both the standard and fast models.
    public let tier: ModelTier
    public init(tier: ModelTier = .standard) { self.tier = tier }
    public var modelTier: ModelTier { tier }
    /// Small and fixed: the backend recognises this exact probe and never counts it against the free
    /// plan's premium-model allowance (Backend/src/validate.mjs `isHealthCheck`) — keep them in sync.
    public var maxOutputTokens: Int { 1024 }

    public var systemPrompt: String { "Reply with {\"ok\": true}." }
    public var outputJSONSchema: String {
        #"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}"#
    }
    public func userMessage(for input: Void) -> String { "ping" }
    public func decode(_ rawJSON: String) throws -> Bool {
        try decodeJSON(Ping.self, from: rawJSON).ok
    }

    private struct Ping: Decodable { let ok: Bool }
}
