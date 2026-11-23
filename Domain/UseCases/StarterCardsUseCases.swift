//
//  StarterCardsUseCases.swift
//  EnglishHelper — Domain (use cases)
//
//  An empty deck gets a start: when the language pair is chosen (onboarding) or changed (Settings) and
//  flashcards hold no card at all, the model suggests `count` idioms of the studied language
//  (`StarterCardsTemplate`) and they go STRAIGHT into flashcards — stored and enrolled, ready for the
//  first practice. Nothing happens when flashcards already hold a card: the user's deck is theirs.
//  A phrase that's already in the list (Caught) is enrolled as it is, not written twice.
//

import Foundation

public protocol StarterCardsUseCase: Sendable {
    /// Put starter cards into flashcards if they hold none. Returns how many went in (0: the deck
    /// wasn't empty, or one run is already under way).
    func seedIfEmpty(studiedLanguage: String, nativeLanguage: String) async throws -> Int
}

public actor StarterCardsInteractor: StarterCardsUseCase {
    /// How many cards an empty deck gets.
    public static let count = 5

    private let llm: any LLMClient
    private let expressions: any ExpressionRepository
    private let cards: any ReviewCardRepository
    private let flashcards: any FlashcardsUseCase
    private let now: @Sendable () -> Date
    /// One run at a time: a change of both languages in a row must not seed the deck twice.
    private var running = false

    public init(llm: any LLMClient, expressions: any ExpressionRepository, cards: any ReviewCardRepository,
                flashcards: any FlashcardsUseCase, now: @escaping @Sendable () -> Date = Date.init) {
        self.llm = llm
        self.expressions = expressions
        self.cards = cards
        self.flashcards = flashcards
        self.now = now
    }

    public func seedIfEmpty(studiedLanguage: String, nativeLanguage: String) async throws -> Int {
        guard !running, try await cards.all().isEmpty else { return 0 }
        running = true
        defer { running = false }
        let template = StarterCardsTemplate(studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
        let drafts = try await llm.run(template, input: Self.count).cards
        // The deck may have been filled while the model answered (a move, an import): leave it be.
        guard try await cards.all().isEmpty else { return 0 }

        let studied = { FixCardsInteractor.lettercase($0, language: studiedLanguage) }
        let native = { FixCardsInteractor.lettercase($0, language: nativeLanguage) }
        var existing = Dictionary(try await expressions.all().map { (Expression.matchKey($0.en), $0) },
                                  uniquingKeysWith: { first, _ in first })
        var enroll: [UUID] = []
        var fresh: [Expression] = []
        let start = now()
        for (index, draft) in drafts.prefix(Self.count).enumerated() {
            let key = Expression.matchKey(draft.expression)
            if let phrase = existing[key] {
                if !enroll.contains(phrase.id) { enroll.append(phrase.id) }
                continue
            }
            // A second apart, so the list keeps the model's order (oldest first).
            let phrase = Expression(en: studied(draft.expression), ru: native(draft.translation),
                                    example: studied(draft.example), synonyms: draft.synonyms.map(studied),
                                    context: native(draft.context),
                                    createdAt: start.addingTimeInterval(Double(index)))
            existing[key] = phrase
            fresh.append(phrase)
            enroll.append(phrase.id)
        }
        if !fresh.isEmpty { try await expressions.addAll(fresh) }
        for id in enroll { try await flashcards.enroll(id, now: start) }
        return enroll.count
    }
}
