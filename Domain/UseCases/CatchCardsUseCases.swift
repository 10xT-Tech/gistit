//
//  CatchCardsUseCases.swift
//  EnglishHelper — Domain (use cases)
//
//  Caught → "From photos": each photo (one LLM request per photo — the backend takes one image per
//  request) becomes vocabulary cards (`PhotoCardsTemplate`), stored on the Caught list as they come.
//  Expressions already saved are skipped, so re-running a photo never duplicates cards.
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

    public var fraction: Double { total == 0 ? 1 : Double(processed) / Double(total) }

    public init(processed: Int, total: Int, added: Int, failed: Int, empty: Int = 0, lastError: LLMError? = nil) {
        self.processed = processed
        self.total = total
        self.added = added
        self.failed = failed
        self.empty = empty
        self.lastError = lastError
    }
}

public protocol CatchCardsFromPhotosUseCase: Sendable {
    /// Yields progress at the start and after every photo, then finishes. Ends by throwing when going
    /// on can't help — offline, the free plan's limit, no API key, cancellation — keeping what's stored.
    func callAsFunction(_ images: [RecognizableImage], studiedLanguage: String, nativeLanguage: String)
        -> AsyncThrowingStream<CatchProgress, Error>
}

public struct CatchCardsFromPhotosInteractor: CatchCardsFromPhotosUseCase {
    private let llm: LLMClient
    private let repository: ExpressionRepository
    private let analytics: (any AnalyticsTracking)?

    public init(llm: LLMClient, repository: ExpressionRepository, analytics: (any AnalyticsTracking)? = nil) {
        self.llm = llm
        self.repository = repository
        self.analytics = analytics
    }

    public func callAsFunction(_ images: [RecognizableImage], studiedLanguage: String, nativeLanguage: String)
        -> AsyncThrowingStream<CatchProgress, Error> {
        let llm = self.llm, repository = self.repository, analytics = self.analytics
        let template = PhotoCardsTemplate(studiedLanguage: studiedLanguage, nativeLanguage: nativeLanguage)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var added = 0, failed = 0, empty = 0
                var lastError: LLMError?
                continuation.yield(CatchProgress(processed: 0, total: images.count, added: 0, failed: 0))
                for (index, image) in images.enumerated() {
                    do {
                        try Task.checkCancellation()
                        let result = try await Self.ask(llm, template, about: image)
                        if result.cards.isEmpty { empty += 1 }
                        for draft in result.cards {
                            guard try await repository.find(en: draft.expression) == nil else { continue }
                            // The letter case Fix cards writes, whatever the model did ("i'm" → "I'm").
                            let studied = { FixCardsInteractor.lettercase($0, language: studiedLanguage) }
                            let native = { FixCardsInteractor.lettercase($0, language: nativeLanguage) }
                            try await repository.add(Expression(en: studied(draft.expression), ru: native(draft.translation),
                                                                example: studied(draft.example),
                                                                synonyms: draft.synonyms.map(studied),
                                                                context: native(draft.context)))
                            added += 1
                        }
                        analytics?.track(.photoCardsCompleted)
                    } catch {
                        guard Self.canGoOn(after: error) else {
                            continuation.finish(throwing: error)
                            return
                        }
                        failed += 1
                        lastError = (error as? LLMError) ?? .requestFailed(String(describing: error))
                    }
                    continuation.yield(CatchProgress(processed: index + 1, total: images.count,
                                                      added: added, failed: failed, empty: empty,
                                                      lastError: lastError))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The cards for one photo — asked again once if the first answer fails in a way the next try
    /// might not (an unreadable answer, a server hiccup).
    private static func ask(_ llm: LLMClient, _ template: PhotoCardsTemplate,
                            about image: RecognizableImage) async throws -> PhotoCardsResult {
        do {
            return try await llm.run(template, input: image)
        } catch let error where canGoOn(after: error) {
            return try await llm.run(template, input: image)
        }
    }

    /// One photo's failure (an unreadable answer, a server error) mustn't stop the rest; a failure the
    /// next photo would hit too does.
    static func canGoOn(after error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let llm = error as? LLMError else { return true }
        switch llm {
        case .offline, .cancelled, .notConfigured, .subscriptionRequired: return false
        default: return true
        }
    }
}
