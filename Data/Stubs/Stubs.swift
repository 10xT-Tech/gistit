//
//  Stubs.swift
//  EnglishHelper — Data (stub adapters)
//
//  Each engine port ships a Stub* that simulates LATENCY + FAILURE, so cloud-backed behavior
//  (slow, flaky) is testable before any cloud adapter exists. Distinct from Mock* (instant, happy).
//

import Foundation
import Domain

// MARK: - LLM

public final class StubLLMClient: LLMClient {
    public enum Behavior: Sendable {
        case success
        case malformedJSON
        case timeout
        case failure(LLMError)
    }
    private let behavior: Behavior
    private let latency: Duration

    public init(behavior: Behavior = .success, latency: Duration = .milliseconds(50)) {
        self.behavior = behavior
        self.latency = latency
    }

    public func run<Template: PromptTemplate>(
        _ template: Template,
        input: Template.Input
    ) async throws -> Template.Output {
        do { try await Task.sleep(for: latency) }
        catch { throw LLMError.cancelled }

        switch behavior {
        case .success:      return try template.decode(MockLLMClient.cannedJSON(for: template, input: input))
        case .malformedJSON: return try template.decode("{ not valid json …")
        case .timeout:      throw LLMError.timedOut
        case .failure(let error): throw error
        }
    }
}

// MARK: - Speech recognition

public final class StubSpeechRecognizing: SpeechRecognizing {
    public enum Behavior: Sendable {
        case success
        case failure(SpeechRecognitionError)
    }
    private let behavior: Behavior
    private let latency: Duration

    public init(behavior: Behavior = .success, latency: Duration = .milliseconds(50)) {
        self.behavior = behavior
        self.latency = latency
    }

    public func transcribe() -> AsyncThrowingStream<SpeechTranscript, Error> {
        let behavior = self.behavior
        let latency = self.latency
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: latency)
                    switch behavior {
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    case .success:
                        continuation.yield(SpeechTranscript(text: "как", isFinal: false))
                        try await Task.sleep(for: latency)
                        continuation.yield(SpeechTranscript(text: "как сказать спасибо", isFinal: true))
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// MARK: - Speech synthesis

public final class StubSpeechSynthesizing: SpeechSynthesizing {
    public enum Behavior: Sendable {
        case success
        case failure(SpeechSynthesisError)
    }
    private let behavior: Behavior
    private let latency: Duration

    public init(behavior: Behavior = .success, latency: Duration = .milliseconds(50)) {
        self.behavior = behavior
        self.latency = latency
    }

    public func speak(_ text: String) -> AsyncThrowingStream<SpeechPlaybackState, Error> {
        let behavior = self.behavior
        let latency = self.latency
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.preparing)
                    try await Task.sleep(for: latency)
                    switch behavior {
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    case .success:
                        continuation.yield(.speaking(progress: 0.5))
                        try await Task.sleep(for: latency)
                        continuation.yield(.finished)
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// MARK: - OCR

public final class StubTextRecognizing: TextRecognizing {
    public enum Behavior: Sendable {
        case success
        case failure(TextRecognitionError)
    }
    private let behavior: Behavior
    private let latency: Duration

    public init(behavior: Behavior = .success, latency: Duration = .milliseconds(50)) {
        self.behavior = behavior
        self.latency = latency
    }

    public func recognizeText(in image: RecognizableImage) async throws -> RecognizedText {
        do { try await Task.sleep(for: latency) }
        catch { throw TextRecognitionError.cancelled }

        switch behavior {
        case .failure(let error):
            throw error
        case .success:
            let text = "Please mind the gap."
            return RecognizedText(
                fullText: text,
                blocks: [RecognizedTextBlock(
                    text: text,
                    boundingBox: NormalizedRect(x: 0.1, y: 0.4, width: 0.8, height: 0.1),
                    confidence: 0.95
                )]
            )
        }
    }
}

// MARK: - Subscription

/// A fixed plan — UI tests of the free-plan gates (`-uiTestFreePlan`), which StoreKit can't fake
/// without a purchase flow.
public struct StubSubscriptionManaging: SubscriptionManaging {
    private let tier: AccessTier
    public init(tier: AccessTier) { self.tier = tier }
    public func currentTier() async -> AccessTier { tier }
    public func tierUpdates() -> AsyncStream<AccessTier> {
        let tier = self.tier
        return AsyncStream { $0.yield(tier); $0.finish() }
    }
    public func refresh() async {}
    public func restorePurchases() async throws {}
}
