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

    public var fraction: Double { total == 0 ? 1 : Double(processed) / Double(total) }

    public init(processed: Int, total: Int, added: Int, failed: Int) {
        self.processed = processed
        self.total = total
        self.added = added
        self.failed = failed
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
                var added = 0, failed = 0
                continuation.yield(CatchProgress(processed: 0, total: images.count, added: 0, failed: 0))
                for (index, image) in images.enumerated() {
                    do {
                        try Task.checkCancellation()
                        let result = try await llm.run(template, input: image)
                        for draft in result.cards {
                            guard try await repository.find(en: draft.expression) == nil else { continue }
                            try await repository.add(Expression(en: draft.expression, ru: draft.translation,
                                                                example: draft.example, synonyms: draft.synonyms))
                            added += 1
                        }
                        analytics?.track(.photoCardsCompleted)
                    } catch {
                        guard Self.canGoOn(after: error) else {
                            continuation.finish(throwing: error)
                            return
                        }
                        failed += 1
                    }
                    continuation.yield(CatchProgress(processed: index + 1, total: images.count,
                                                      added: added, failed: failed))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
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
