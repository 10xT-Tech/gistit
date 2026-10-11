//
//  ConnectionUseCase.swift
//  EnglishHelper — Domain (use case)
//
//  Live connection health for Settings — runs the cheapest possible LLM round-trip and maps any
//  failure to a domain status.
//

import Foundation

public enum ConnectionHealth: Sendable, Equatable {
    case ok
    case failed(Reason)
    case cancelled   // the check was cancelled (e.g. Settings dismissed) — caller should keep prior status

    /// Localizable failure reasons (the UI maps these to text).
    public enum Reason: Sendable, Equatable {
        case noKey, unauthorized, offline, timeout, overloaded, badResponse, unavailable, unknown
    }
}

public protocol ConnectionHealthUseCase: Sendable {
    /// Probe a specific model tier (standard / fast) so Settings can show both models' status.
    func callAsFunction(_ tier: ModelTier) async -> ConnectionHealth
}

public extension ConnectionHealthUseCase {
    /// Back-compat convenience: probe the standard model.
    func callAsFunction() async -> ConnectionHealth { await callAsFunction(.standard) }
}

public struct ConnectionHealthInteractor: ConnectionHealthUseCase {
    private let llm: LLMClient
    public init(llm: LLMClient) { self.llm = llm }

    public func callAsFunction(_ tier: ModelTier) async -> ConnectionHealth {
        do {
            _ = try await llm.run(HealthCheckTemplate(tier: tier), input: ())
            return .ok
        } catch let error as LLMError {
            switch error {
            case .notConfigured: return .failed(.noKey)
            case .overloaded: return .failed(.overloaded)
            case .offline: return .failed(.offline)
            case .timedOut: return .failed(.timeout)
            case .responseTooLong: return .failed(.badResponse)   // not expected for the tiny health ping
            case .requestFailed: return .failed(.unavailable)
            case .invalidOutput: return .failed(.badResponse)
            case .cancelled: return .cancelled   // sheet dismissed mid-check — not a connectivity fault
            case .subscriptionRequired: return .ok   // reachable and authorised; only the plan limits it
            }
        } catch {
            return .failed(.unknown)
        }
    }
}

// MARK: - Transcription service (Soniox) health

public protocol TranscriptionHealthUseCase: Sendable {
    /// Probe the cloud transcription service so Settings can show its status alongside Claude's.
    func callAsFunction() async -> ConnectionHealth
}

public struct TranscriptionHealthInteractor: TranscriptionHealthUseCase {
    private let service: any TranscriptionServiceChecking
    public init(service: any TranscriptionServiceChecking) { self.service = service }

    public func callAsFunction() async -> ConnectionHealth {
        do {
            try await service.ping()
            return .ok
        } catch let error as TranscriptionServiceError {
            switch error {
            case .notConfigured: return .failed(.noKey)
            case .unauthorized: return .failed(.unauthorized)
            case .offline: return .failed(.offline)
            case .timedOut: return .failed(.timeout)
            case .unavailable: return .failed(.unavailable)
            case .badResponse: return .failed(.badResponse)
            case .cancelled: return .cancelled   // sheet dismissed mid-check — not a connectivity fault
            }
        } catch {
            return .failed(.unknown)
        }
    }
}
