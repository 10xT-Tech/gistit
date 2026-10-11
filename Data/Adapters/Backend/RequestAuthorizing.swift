//
//  RequestAuthorizing.swift
//  EnglishHelper — Data
//
//  How a Messages API request is authenticated: directly with an Anthropic key (development only —
//  the key ships in the app), or with a session token from our backend (`BackendSession`), which
//  holds the real key and forwards the request.
//

import Foundation

public protocol RequestAuthorizing: Sendable {
    /// False when no credential exists at all — the client fails fast with `.notConfigured`.
    var isConfigured: Bool { get }
    /// Adds the credential headers to `request`.
    func authorize(_ request: inout URLRequest) async throws
    /// The server rejected the credential (401/403). True if a fresh credential may succeed, so the
    /// request is worth one retry.
    func credentialRejected() async -> Bool
}

/// Direct Anthropic API access with an embedded key. Development builds only: the key is extractable.
public struct DirectAPIKeyAuthorizer: RequestAuthorizing {
    private let apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }

    public var isConfigured: Bool { !apiKey.isEmpty }

    public func authorize(_ request: inout URLRequest) async throws {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    public func credentialRejected() async -> Bool { false }
}
