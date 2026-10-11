//
//  BackendSession.swift
//  EnglishHelper — Data (live adapter)
//
//  The app's identity with our own backend (Backend/ — AWS Lambda), so NO third-party API key ships
//  in the app. Flow, matching Backend/src/index.mjs:
//    1. once per install: App Attest key → attestation over a server challenge → POST /v1/attest/register
//    2. per ~hour: assertion over a fresh challenge → POST /v1/session → short-lived bearer token
//    3. the token authorizes the Claude proxy (/v1/messages) and Soniox temporary keys.
//  Client data for every attestation/assertion is the challenge string's UTF-8 bytes.
//  App Attest isn't available on the Simulator; DEBUG builds may fall back to a dev token instead.
//  Opening a session also sends the App Store's signed AppTransaction + subscription transaction
//  (`EntitlementProofs`), from which the backend decides the access tier baked into the token.
//

import Foundation
import CryptoKit
import DeviceCheck
import Domain
import os

private let backendLog = Logger(subsystem: "tech.10xt.englishhelper", category: "backend")

public enum BackendError: Error, Sendable, Equatable {
    case attestationUnsupported   // no App Attest (Simulator) and no dev token
    case offline
    case timedOut
    case rateLimited
    case subscriptionRequired(retryAfter: Int?)   // HTTP 402 — the user's plan doesn't include this
    case rejected(String)         // the backend refused our attestation / session (error type)
    case server(Int)              // any other non-2xx
    case badResponse
}

/// StoreKit's signed (JWS) evidence of how the app was obtained and what the user subscribes to.
public struct EntitlementProofs: Sendable {
    public let appTransaction: String?
    public let subscription: String?
    public init(appTransaction: String?, subscription: String?) {
        self.appTransaction = appTransaction
        self.subscription = subscription
    }
    public static let none = EntitlementProofs(appTransaction: nil, subscription: nil)
}

public actor BackendSession: RequestAuthorizing {
    private let baseURL: URL
    private let proofs: @Sendable () async -> EntitlementProofs
    private let urlSession: URLSession
    private let defaults: UserDefaults
    private let devToken: String?
    private var token: (value: String, expires: Date)?
    private var opening: Task<String, Error>?

    private static let keyIdDefaultsKey = "backend.appAttestKeyId"

    /// `devToken` is honoured only in DEBUG builds, and only where App Attest is unsupported.
    public init(baseURL: URL, devToken: String? = nil, session: URLSession = .shared,
                defaults: UserDefaults = .standard,
                proofs: @escaping @Sendable () async -> EntitlementProofs = { .none }) {
        self.baseURL = baseURL
        self.proofs = proofs
        self.devToken = devToken
        self.urlSession = session
        self.defaults = defaults
    }

    // MARK: RequestAuthorizing

    public nonisolated var isConfigured: Bool { true }

    public func authorize(_ request: inout URLRequest) async throws {
        request.setValue("Bearer \(try await sessionToken())", forHTTPHeaderField: "Authorization")
    }

    public func credentialRejected() async -> Bool {
        token = nil
        return true
    }

    /// The user's plan changed (purchase, renewal, expiry): the next request opens a new session,
    /// so the backend re-reads the tier.
    public func refreshEntitlements() {
        token = nil
    }

    // MARK: Soniox

    /// A single-use Soniox key valid for ~60 s — enough to open one WebSocket.
    public func sonioxTemporaryKey() async throws -> String {
        struct Response: Decodable { let api_key: String }
        for attempt in 0..<2 {
            let bearer = try await sessionToken()
            let (status, data) = try await post("v1/soniox/temporary-key", body: [String: String](),
                                                 headers: ["Authorization": "Bearer \(bearer)"])
            if status == 401, attempt == 0 { token = nil; continue }   // session expired server-side
            try Self.check(status, data)
            guard let key = try? JSONDecoder().decode(Response.self, from: data).api_key else {
                throw BackendError.badResponse
            }
            return key
        }
        throw BackendError.rejected("invalid_session")
    }

    // MARK: Session token

    private func sessionToken() async throws -> String {
        if let token, token.expires > Date().addingTimeInterval(60) { return token.value }
        if let opening { return try await opening.value }   // coalesce concurrent callers
        let task = Task { try await self.openSession() }
        opening = task
        defer { opening = nil }
        return try await task.value
    }

    private func openSession() async throws -> String {
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            #if DEBUG
            if let devToken, !devToken.isEmpty { return try await openDevSession(devToken) }
            #endif
            throw BackendError.attestationUnsupported
        }
        do {
            return try await assertSession(keyId: try await attestedKeyId())
        } catch let error as BackendError where error == .rejected("unknown_key") || error == .rejected("key_revoked") {
            backendLog.notice("backend no longer knows our key; re-attesting")
        } catch let error as DCError where error.code == .invalidKey {
            backendLog.notice("App Attest key invalidated (restore / reinstall); re-attesting")
        }
        defaults.removeObject(forKey: Self.keyIdDefaultsKey)
        return try await assertSession(keyId: try await attestedKeyId())
    }

    /// The registered App Attest key id, attesting a new key first if there is none yet.
    private func attestedKeyId() async throws -> String {
        if let keyId = defaults.string(forKey: Self.keyIdDefaultsKey) { return keyId }
        let service = DCAppAttestService.shared
        let keyId = try await service.generateKey()
        let challenge = try await fetchChallenge()
        let attestation = try await service.attestKey(keyId, clientDataHash: Self.hash(challenge))
        let (status, data) = try await post("v1/attest/register", body: [
            "keyId": keyId, "attestation": attestation.base64EncodedString(), "challenge": challenge,
        ])
        try Self.check(status, data)
        defaults.set(keyId, forKey: Self.keyIdDefaultsKey)   // only once the backend accepted it
        backendLog.info("App Attest key registered")
        return keyId
    }

    private func assertSession(keyId: String) async throws -> String {
        let challenge = try await fetchChallenge()
        let assertion = try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: Self.hash(challenge))
        let evidence = await proofs()
        var body = ["keyId": keyId, "assertion": assertion.base64EncodedString(), "challenge": challenge]
        body["appTransaction"] = evidence.appTransaction
        body["subscription"] = evidence.subscription
        let (status, data) = try await post("v1/session", body: body)
        return try store(status, data)
    }

    #if DEBUG
    private func openDevSession(_ devToken: String) async throws -> String {
        let (status, data) = try await post("v1/session/dev", body: [String: String](),
                                            headers: ["X-Dev-Token": devToken])
        return try store(status, data)
    }
    #endif

    private func store(_ status: Int, _ data: Data) throws -> String {
        struct Response: Decodable { let token: String; let expiresIn: Double }
        try Self.check(status, data)
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw BackendError.badResponse }
        token = (response.token, Date().addingTimeInterval(response.expiresIn))
        return response.token
    }

    private func fetchChallenge() async throws -> String {
        struct Response: Decodable { let challenge: String }
        let (status, data) = try await post("v1/attest/challenge", body: [String: String]())
        try Self.check(status, data)
        guard let challenge = try? JSONDecoder().decode(Response.self, from: data).challenge else {
            throw BackendError.badResponse
        }
        return challenge
    }

    // MARK: HTTP

    private func post(_ path: String, body: [String: String],
                      headers: [String: String] = [:]) async throws -> (Int, Data) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONEncoder().encode(body)
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw BackendError.badResponse }
            return (http.statusCode, data)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw BackendError.timedOut
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                throw BackendError.offline
            default: throw BackendError.server(0)
            }
        }
    }

    private static func check(_ status: Int, _ data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        struct Envelope: Decodable {
            struct Detail: Decodable { let type: String; let retry_after: Int? }
            let error: Detail
        }
        let detail = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
        let type = detail?.type
        backendLog.error("backend \(status) \(type ?? "-", privacy: .public)")
        switch status {
        case 402: throw BackendError.subscriptionRequired(retryAfter: detail?.retry_after)
        case 429: throw BackendError.rateLimited
        case 401, 403, 404, 409: throw BackendError.rejected(type ?? "unauthorized")
        default: throw BackendError.server(status)
        }
    }

    private static func hash(_ challenge: String) -> Data {
        Data(SHA256.hash(data: Data(challenge.utf8)))
    }
}

// MARK: - Error mapping for each consumer

extension BackendError {
    var llmError: LLMError {
        switch self {
        case .attestationUnsupported: .notConfigured
        case .offline: .offline
        case .timedOut: .timedOut
        case .rateLimited: .overloaded
        case .subscriptionRequired(let retryAfter): .subscriptionRequired(retryAfter: retryAfter)
        case .rejected(let type): .requestFailed("backend refused the app: \(type)")
        case .server(let status): .requestFailed("backend error \(status)")
        case .badResponse: .requestFailed("backend sent an unexpected response")
        }
    }

    var liveTranslationError: LiveTranslationError {
        switch self {
        case .attestationUnsupported: .notConfigured
        case .offline: .offline
        case .timedOut, .rateLimited, .server, .badResponse: .serviceUnavailable
        case .subscriptionRequired: .subscriptionRequired
        case .rejected: .unauthorized
        }
    }

    var transcriptionServiceError: TranscriptionServiceError {
        switch self {
        case .attestationUnsupported: .notConfigured
        case .offline: .offline
        case .timedOut: .timedOut
        case .rateLimited, .server: .unavailable
        case .rejected: .unauthorized
        case .badResponse: .badResponse
        case .subscriptionRequired: .unavailable   // not reached: the health probe treats 402 as reachable
        }
    }
}

/// Settings health probe for the online-translation backend path: minting a temporary Soniox key
/// exercises the whole chain (App Attest session → backend → Soniox account).
public struct BackendTranscriptionHealth: TranscriptionServiceChecking {
    private let backend: BackendSession
    public init(backend: BackendSession) { self.backend = backend }

    public func ping() async throws {
        do {
            _ = try await backend.sonioxTemporaryKey()
        } catch BackendError.subscriptionRequired {
            return   // the service and the backend both answered; only the plan withholds the feature
        } catch let error as BackendError {
            throw error.transcriptionServiceError
        } catch is CancellationError {
            throw TranscriptionServiceError.cancelled
        } catch {
            throw TranscriptionServiceError.unavailable   // App Attest itself failed (DCError)
        }
    }
}
