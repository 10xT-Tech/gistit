//
//  CatchCardsUseCases.swift
//  EnglishHelper — Domain (use cases)
//
//  Caught → "From photos": each photo (one LLM request per photo — the backend takes one image per
//  request) becomes vocabulary cards (`PhotoCardsTemplate`), stored on the Caught list as they come.
//  Every phrase is stored — one already in FLASHCARDS too (Caught marks it) — except one the Caught
//  list already holds as it is (`CaughtPhrases`), so re-running a photo never doubles a Caught row.
//

import Foundation

/// Where a batch of photos stands.
public struct CatchProgress: Sendable, Equatable {
    /// Photos done (with or without cards).
    public let processed: Int
    public let total: Int
    /// New cards stored so far.
    public let added: Int
    /// Photos that failed (unreadable answer, a server hiccup) — the batch went on without them.
    public let failed: Int
    /// Photos with nothing to card: no featured phrase, nothing marked on the page.
    public let empty: Int
    /// Why the last failed photo failed — the sheet says it.
    public let lastError: LLMError?
    /// Phrases not added because Caught had them already (as written there) — a repeat within the batch
    /// isn't listed.
    public let alreadyInCaught: [String]
    /// Phrases added although flashcards have them — the Caught list marks them.
    public let inFlashcards: [String]

    public var fraction: Double { total == 0 ? 1 : Double(processed) / Double(total) }

    public init(processed: Int, total: Int, added: Int, failed: Int, empty: Int = 0, lastError: LLMError? = nil,
                alreadyInCaught: [String] = [], inFlashcards: [String] = []) {
        self.processed = processed
        self.total = total
        self.added = added
        self.failed = failed
        self.empty = empty
        self.lastError = lastError
        self.alreadyInCaught = alreadyInCaught
        self.inFlashcards = inFlashcards
    }
}

public protocol CatchCardsFromPhotosUseCase: Sendable {
    /// Yields progress at the start and after every photo, then finishes. A photo whose answer can't
    /// be used (or whose request is rejected) is skipped (`RunFailure`). Ends by throwing when going on
    /// can't help — offline, the free plan's limit, no API key, cancellation, or the service not
    /// answering for two photos in a row — keeping what's stored.
    func callAsFunction(_ images: [RecognizableImage], studiedLanguage: String, nativeLanguage: String)
        -> AsyncThrowingStream<CatchProgress, Error>
}

public struct CatchCardsFromPhotosInteractor: CatchCardsFromPhotosUseCase {
    private let llm: LLMClient
    private let repository: ExpressionRepository
    private let caught: CaughtPhrases
    private let analytics: (any AnalyticsTracking)?

    /// `cards`: what's in flashcards (nil = nothing is).
    public init(llm: LLMClient, repository: ExpressionRepository, cards: (any ReviewCardRepository)? = nil,
                analytics: (any AnalyticsTracking)? = nil) {
        self.llm = llm
        self.repository = repository
        self.caught = CaughtPhrases(expressions: repository, cards: cards)
        self.analytics = analytics
    }

    public func callAsFunction(_ images: [RecognizableImage], studiedLanguage: String, nativeLanguage: String)
        -> AsyncThrowingStream<CatchProgress, Error> {
        let llm = self.llm, repository = self.repository, caught = self.caught, analytics = self.analytics
        let template = PhotoCardsTemplate(studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var added = 0, failed = 0, empty = 0
                var lastError: LLMError?
                var alreadyInCaught: [String] = [], inFlashcards: [String] = []
                var addedNow = Set<UUID>()             // cards this batch stored — repeats, not "already in Caught"
                continuation.yield(CatchProgress(processed: 0, total: images.count, added: 0, failed: 0))
                /// Photos in a row the service gave no answer for.
                var unanswered = 0
                for (index, image) in images.enumerated() {
                    let outcome: RunOutcome<PhotoCardsResult>
                    do {
                        try Task.checkCancellation()
                        outcome = try await RunRequest.send { try await llm.run(template, input: image) }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    var stoppedBy: (any Error)?
                    switch outcome {
                    case .answer(let result):
                        unanswered = 0
                        do {
                            if result.cards.isEmpty { empty += 1 }
                            for draft in result.cards {
                                if let existing = try await caught.inCaught(draft.expression) {
                                    if !addedNow.contains(existing.id), !alreadyInCaught.contains(existing.en) {
                                        alreadyInCaught.append(existing.en)
                                    }
                                    continue
                                }
                                if try await caught.inFlashcards(draft.expression) {
                                    inFlashcards.append(draft.expression)
                                }
                                // The letter case Fix cards writes, whatever the model did ("i'm" → "I'm").
                                let studied = { FixCardsInteractor.lettercase($0, language: studiedLanguage) }
                                let native = { FixCardsInteractor.lettercase($0, language: nativeLanguage) }
                                let card = Expression(en: studied(draft.expression), ru: native(draft.translation),
                                                      example: studied(draft.example), synonyms: draft.synonyms.map(studied),
                                                      context: native(draft.context))
                                try await repository.add(card)
                                addedNow.insert(card.id)
                                added += 1
                            }
                            analytics?.track(.photoCardsCompleted)
                        } catch {
                            failed += 1                                 // its cards couldn't be stored
                            lastError = .requestFailed(String(describing: error))
                        }
                    case .none(let error, let failure):
                        failed += 1
                        lastError = (error as? LLMError) ?? .requestFailed(String(describing: error))
                        // One photo the service didn't answer for may be that photo's weight; a
                        // second in a row is the service — the rest would only spend requests.
                        unanswered = failure == .service ? unanswered + 1 : 0
                        if unanswered == Self.unansweredLimit { stoppedBy = error }
                    }
                    continuation.yield(CatchProgress(processed: index + 1, total: images.count,
                                                      added: added, failed: failed, empty: empty,
                                                      lastError: lastError, alreadyInCaught: alreadyInCaught,
                                                      inFlashcards: inFlashcards))
                    if let stoppedBy {
                        continuation.finish(throwing: stoppedBy)
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Photos in a row without the service's answer (each asked twice) after which the batch stops.
    static let unansweredLimit = 2
}
