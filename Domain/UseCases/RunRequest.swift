//
//  RunRequest.swift
//  EnglishHelper — Domain (use cases)
//
//  One request among the MANY of a run — a Fix cards batch, a batch of the duplicates Check, one photo
//  of "cards from photos". What its failure means for the rest of the run is decided here, once, for
//  all three:
//  - `stopsRun` — asking again can't help now (no network, the plan's or the day's limit, no key,
//    cancelled): the run ends at once, with that error;
//  - `service`  — the SERVICE didn't answer (a timeout, an overload, a server or transport error):
//    worth one more try; the next request would hit it too, so the caller stops the run rather than
//    walk the rest of it through a dead service;
//  - `rejected` — the service refused THIS request as it is (a 4xx): the same content again can't
//    help, another request may well go through — no second try, the run goes on;
//  - `answer`   — the service answered and the answer can't be used (not the schema, cut off at the
//    token budget, declined): this request's trouble — one more try, then the run goes on.
//  Each caller decides what "goes on" leaves behind (Fix cards remembers the phrases, the Check leaves
//  the groups unchecked, a photo is skipped) and when a streak of unanswered requests stops being
//  "this request's trouble".
//

import Foundation

public enum RunFailure: Equatable, Sendable {
    case stopsRun
    case service
    case rejected
    case answer

    public init(_ error: any Error) {
        guard !(error is CancellationError) else { self = .stopsRun; return }
        guard let llm = error as? LLMError else { self = .answer; return }
        switch llm {
        case .offline, .cancelled, .notConfigured, .subscriptionRequired, .dailyLimitReached: self = .stopsRun
        case .timedOut, .overloaded, .requestFailed: self = .service
        case .requestRejected: self = .rejected
        case .invalidOutput, .responseTooLong: self = .answer
        }
    }
}

/// What came of one request of a run.
enum RunOutcome<Value: Sendable>: Sendable {
    case answer(Value)
    /// No answer — after the second try, where one was worth it. Never `.stopsRun` (that one throws).
    case none(any Error, RunFailure)
}

enum RunRequest {
    /// Sends the request, once more after a failure another try might get over. THROWS when the run
    /// must end at once (`RunFailure.stopsRun`).
    static func send<Value: Sendable>(_ request: @Sendable () async throws -> Value) async throws -> RunOutcome<Value> {
        var isSecondTry = false
        while true {
            do {
                return .answer(try await request())
            } catch {
                let failure = RunFailure(error)
                switch failure {
                case .stopsRun: throw error
                case .rejected: return .none(error, failure)
                case .service, .answer:
                    if isSecondTry { return .none(error, failure) }
                    isSecondTry = true
                }
            }
        }
    }
}
