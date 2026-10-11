//
//  ClaudeLLMClientTests.swift
//  EnglishHelperTests
//
//  ClaudeLLMClient retry/backoff behavior on transient overload (429/529), via a stub URLProtocol.
//

import Testing
import Foundation
import Domain
import Adapters

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 529
    nonisolated(unsafe) static var callCount = 0
    /// When set, returned as the response body (e.g. a 200 Messages envelope); else a canned error.
    nonisolated(unsafe) static var responseBody: Data? = nil
    /// Captures the LAST outgoing request body (de-streamed) so tests can assert what was sent on the wire.
    nonisolated(unsafe) static var lastBody: Data? = nil
    /// Simulate a transport failure: fail the first `failTimes` attempts with `failCode`, then serve normally.
    nonisolated(unsafe) static var failCode: URLError.Code? = nil
    nonisolated(unsafe) static var failTimes = 0
    /// Per-call status codes (call 1 → [0], …); calls past the end use `statusCode`.
    nonisolated(unsafe) static var statusSequence: [Int] = []
    /// Captures the LAST request's credential headers.
    nonisolated(unsafe) static var lastAuthorization: String? = nil
    nonisolated(unsafe) static var lastAPIKey: String? = nil
    nonisolated(unsafe) static var responseHeaders: [String: String]? = nil

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    /// URLSession hands the protocol the body as a STREAM (httpBody is nil), so drain the stream.
    static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 8192
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func startLoading() {
        StubURLProtocol.lastBody = StubURLProtocol.bodyData(of: request)
        StubURLProtocol.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        StubURLProtocol.lastAPIKey = request.value(forHTTPHeaderField: "x-api-key")
        StubURLProtocol.callCount += 1
        if let code = StubURLProtocol.failCode, StubURLProtocol.callCount <= StubURLProtocol.failTimes {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let index = StubURLProtocol.callCount - 1
        let status = index < StubURLProtocol.statusSequence.count
            ? StubURLProtocol.statusSequence[index] : StubURLProtocol.statusCode
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: StubURLProtocol.responseHeaders
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = StubURLProtocol.responseBody
            ?? Data(#"{"type":"error","error":{"type":"overloaded_error"}}"#.utf8)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct ClaudeLLMClientTests {

    private func makeClient(maxRetries: Int = 2) -> ClaudeLLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ClaudeLLMClient(
            apiKey: "sk-test", model: "claude-sonnet-5-5",
            baseURL: URL(string: "https://api.anthropic.com")!,
            session: URLSession(configuration: config),
            maxRetries: maxRetries, baseRetryDelay: 0.001
        )
    }

    /// A canned SSE (Server-Sent Events) body — the streaming Messages API's 200 response shape.
    /// The text is split into two `content_block_delta` events to prove the client ACCUMULATES
    /// deltas rather than reading just one.
    private func sse(_ text: String, stopReason: String = "end_turn") throws -> Data {
        var lines = ["event: message_start", #"data: {"type":"message_start"}"#, ""]
        let mid = text.index(text.startIndex, offsetBy: text.count / 2)
        for part in [String(text[..<mid]), String(text[mid...])] where !part.isEmpty {
            let delta = try JSONSerialization.data(withJSONObject: [
                "type": "content_block_delta", "index": 0,
                "delta": ["type": "text_delta", "text": part],
            ])
            lines += ["event: content_block_delta", "data: " + String(decoding: delta, as: UTF8.self), ""]
        }
        lines += ["event: message_delta", #"data: {"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"}}"#, ""]
        lines += ["event: message_stop", #"data: {"type":"message_stop"}"#, ""]
        return Data(lines.joined(separator: "\n").utf8)
    }

    @Test func retriesThenThrowsOverloadedOn529() async {
        StubURLProtocol.statusCode = 529
        StubURLProtocol.callCount = 0
        let client = makeClient(maxRetries: 2)

        await #expect(throws: LLMError.overloaded) {
            _ = try await client.run(UnderstandTemplate(), input: "hello")
        }
        #expect(StubURLProtocol.callCount == 3)   // 1 initial + 2 retries
    }

    @Test func throwsOverloadedOn429() async {
        StubURLProtocol.statusCode = 429
        StubURLProtocol.callCount = 0
        StubURLProtocol.responseBody = nil
        let client = makeClient(maxRetries: 1)

        await #expect(throws: LLMError.overloaded) {
            _ = try await client.run(UnderstandTemplate(), input: "hello")
        }
        #expect(StubURLProtocol.callCount == 2)   // 1 initial + 1 retry
    }

    /// A transient transport blip (e.g. the connection drops mid-request) must be RETRIED with backoff,
    /// not surfaced immediately — so a momentary mobile-network hiccup recovers silently.
    @Test func retriesTransientTransportErrorThenSucceeds() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.callCount = 0
        StubURLProtocol.responseBody = try sse(#"{"ok":true}"#)
        StubURLProtocol.failCode = .networkConnectionLost
        StubURLProtocol.failTimes = 2                 // first 2 attempts drop, 3rd succeeds
        defer {
            StubURLProtocol.failCode = nil; StubURLProtocol.failTimes = 0
            StubURLProtocol.responseBody = nil; StubURLProtocol.statusCode = 529
        }

        let client = makeClient(maxRetries: 3)
        let ok = try await client.run(HealthCheckTemplate(), input: ())
        #expect(ok)                                   // recovered after the transient failures
        #expect(StubURLProtocol.callCount == 3)       // 2 failed + 1 success
    }

    /// A SUSTAINED transport failure (every attempt drops) must surface as an error only after the
    /// retries are exhausted — proving the blip is retried, not shown immediately.
    @Test func sustainedTransportErrorSurfacesAfterRetries() async {
        StubURLProtocol.callCount = 0
        StubURLProtocol.failCode = .networkConnectionLost
        StubURLProtocol.failTimes = .max             // never recovers
        defer { StubURLProtocol.failCode = nil; StubURLProtocol.failTimes = 0; StubURLProtocol.statusCode = 529 }

        let client = makeClient(maxRetries: 2)
        await #expect(throws: LLMError.self) {
            _ = try await client.run(HealthCheckTemplate(), input: ())
        }
        #expect(StubURLProtocol.callCount == 3)       // 1 initial + 2 retries, THEN the error
    }

    /// A backend session that expired server-side (401) is renewed ONCE and the request retried with
    /// the new token; the backend path never sends an Anthropic key.
    @Test func renewsRejectedBackendSessionOnceAndRetries() async throws {
        actor FakeSession: RequestAuthorizing {
            private var issued = 0
            private(set) var rejections = 0
            nonisolated var isConfigured: Bool { true }
            func authorize(_ request: inout URLRequest) async throws {
                issued += 1
                request.setValue("Bearer token-\(issued)", forHTTPHeaderField: "Authorization")
            }
            func credentialRejected() async -> Bool { rejections += 1; return true }
        }
        StubURLProtocol.statusCode = 200
        StubURLProtocol.statusSequence = [401]
        StubURLProtocol.callCount = 0
        StubURLProtocol.responseBody = try sse(#"{"ok":true}"#)
        defer {
            StubURLProtocol.responseBody = nil; StubURLProtocol.statusCode = 529
            StubURLProtocol.statusSequence = []; StubURLProtocol.lastAuthorization = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = FakeSession()
        let client = ClaudeLLMClient(
            authorizer: session, model: "claude-sonnet-5-5",
            baseURL: URL(string: "https://backend.example")!,
            session: URLSession(configuration: config), maxRetries: 1, baseRetryDelay: 0.001
        )
        let ok = try await client.run(HealthCheckTemplate(), input: ())
        #expect(ok)
        #expect(StubURLProtocol.callCount == 2)                       // 401, then the retry
        #expect(StubURLProtocol.lastAuthorization == "Bearer token-2")  // with the RENEWED token
        #expect(StubURLProtocol.lastAPIKey == nil)                     // no Anthropic key on the wire
        #expect(await session.rejections == 1)
    }

    /// HTTP 402 from our backend = the free plan's limit: surfaced with its wait, and NEVER retried.
    @Test func freePlanLimitIsNotRetried() async throws {
        StubURLProtocol.statusCode = 402
        StubURLProtocol.callCount = 0
        StubURLProtocol.responseHeaders = ["Retry-After": "240"]
        StubURLProtocol.responseBody = Data(#"{"error":{"type":"subscription_required","retry_after":240}}"#.utf8)
        defer {
            StubURLProtocol.statusCode = 529; StubURLProtocol.responseHeaders = nil; StubURLProtocol.responseBody = nil
        }
        do {
            _ = try await makeClient().run(HealthCheckTemplate(), input: ())
            Issue.record("expected subscriptionRequired")
        } catch {
            #expect(error as? LLMError == .subscriptionRequired(retryAfter: 240))
        }
        #expect(StubURLProtocol.callCount == 1)
    }

    /// The Settings probe is small and fixed — the backend's `isHealthCheck` relies on this shape.
    @Test func healthProbeMatchesTheBackendExemption() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.callCount = 0
        StubURLProtocol.responseBody = try sse(#"{"ok":true}"#)
        defer { StubURLProtocol.statusCode = 529; StubURLProtocol.responseBody = nil; StubURLProtocol.lastBody = nil }
        _ = try await makeClient().run(HealthCheckTemplate(), input: ())
        let body = try #require(StubURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["system"] as? String == #"Reply with {"ok": true}."#)
        #expect((json["max_tokens"] as? Int ?? .max) <= 1024)
        let content = try #require(((json["messages"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content.first?["text"] as? String == "ping")
    }

    /// A rejected DIRECT key can't get better by retrying: one call, then `.notConfigured`.
    @Test func doesNotRetryRejectedDirectKey() async throws {
        StubURLProtocol.statusCode = 401
        StubURLProtocol.callCount = 0
        defer { StubURLProtocol.statusCode = 529 }
        do {
            _ = try await makeClient().run(HealthCheckTemplate(), input: ())
            Issue.record("expected notConfigured")
        } catch {
            #expect(error as? LLMError == .notConfigured)
        }
        #expect(StubURLProtocol.callCount == 1)
    }

    /// Regression: the template's schema must reach the wire VERBATIM — same property ORDER. It used to
    /// round-trip through a Swift dictionary, whose order is randomised per process; with `context_ru`
    /// ahead of `en`, Sonnet answered Say it with one empty placeholder item ("Couldn't parse").
    @Test func sendsTemplateSchemaVerbatimPreservingPropertyOrder() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = try sse(#"{"zeta":"z","alpha":"a","mid":"m"}"#)
        defer {
            StubURLProtocol.responseBody = nil; StubURLProtocol.statusCode = 529; StubURLProtocol.lastBody = nil
        }
        let template = OrderedSchemaTemplate()
        _ = try await makeClient().run(template, input: ())

        let body = String(decoding: try #require(StubURLProtocol.lastBody), as: UTF8.self)
        #expect(body.contains(template.outputJSONSchema))   // spliced in as written, not re-encoded
        let zeta = try #require(body.range(of: #""zeta""#)), alpha = try #require(body.range(of: #""alpha""#))
        #expect(zeta.lowerBound < alpha.lowerBound)         // NOT alphabetised / shuffled
        // …and the whole body is still valid JSON with the schema as an object.
        let json = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let format = try #require((json["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["schema"] is [String: Any])
    }

    /// Regression: `output_config.effort` must NOT be sent to a legacy Haiku — Haiku 4.5 hard-400s on it
    /// ("does not support the effort parameter"), which would break EVERY request routed to the fast
    /// model. Haiku 5.5 and Sonnet 5.5 DO receive it (without it Haiku 5.5 runs at its slower `medium`
    /// default). Every request carries the template schema as the structured-output format, and no
    /// `thinking` field (neither 5.5 model accepts "disabled").
    @Test func sendsEffortToCurrentModelsButNotLegacyHaiku() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = try sse(#"{"ok":true}"#)
        defer {
            StubURLProtocol.responseBody = nil; StubURLProtocol.statusCode = 529; StubURLProtocol.lastBody = nil
        }

        func wireJSON(model: String, fastModel: String, tier: ModelTier) async throws -> [String: Any] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubURLProtocol.self]
            let client = ClaudeLLMClient(
                apiKey: "sk-test", model: model, fastModel: fastModel,
                baseURL: URL(string: "https://api.anthropic.com")!,
                session: URLSession(configuration: config), maxRetries: 1, baseRetryDelay: 0.001
            )
            StubURLProtocol.callCount = 0; StubURLProtocol.lastBody = nil
            _ = try await client.run(HealthCheckTemplate(tier: tier), input: ())
            let body = try #require(StubURLProtocol.lastBody)
            return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        func effort(_ json: [String: Any]) -> String? {
            (json["output_config"] as? [String: Any])?["effort"] as? String
        }

        // Fast tier → Haiku 5.5 → effort present, schema as the structured-output format.
        let haiku = try await wireJSON(model: "claude-sonnet-5-5", fastModel: "claude-haiku-5-5", tier: .fast)
        #expect(haiku["model"] as? String == "claude-haiku-5-5")   // .fast tier really reached the wire
        #expect(effort(haiku) == "low")
        let format = try #require((haiku["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect((format["schema"] as? [String: Any])?["additionalProperties"] as? Bool == false)
        #expect(haiku["thinking"] == nil)

        // Standard tier → Sonnet 5.5 → effort present.
        let sonnet = try await wireJSON(model: "claude-sonnet-5-5", fastModel: "claude-haiku-5-5", tier: .standard)
        #expect(sonnet["model"] as? String == "claude-sonnet-5-5")
        #expect(effort(sonnet) == "low")

        // A legacy Haiku 4.5 configured as the fast model → effort omitted, format still sent.
        let legacy = try await wireJSON(model: "claude-sonnet-5-5", fastModel: "claude-haiku-4-5", tier: .fast)
        #expect(legacy["model"] as? String == "claude-haiku-4-5")
        let legacyConfig = try #require(legacy["output_config"] as? [String: Any])
        #expect(legacyConfig["effort"] == nil)                 // ← no effort to Haiku 4.5
        #expect(legacyConfig["format"] != nil)
    }

    /// Regression for the same root cause: per-template tuning (`maxOutputTokens` / `prefersFastResponse`)
    /// must reach the wire through the GENERIC client. They were declared only in a protocol extension, so
    /// the client statically dispatched to the defaults (2048 / true) and ignored EVERY override — which
    /// silently capped the photo translator's output budget and forced it to low effort.
    @Test func honorsPerTemplateTuningOverridesThroughClient() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = try sse(#"{"ok":true}"#)
        StubURLProtocol.callCount = 0; StubURLProtocol.lastBody = nil
        defer {
            StubURLProtocol.responseBody = nil; StubURLProtocol.statusCode = 529; StubURLProtocol.lastBody = nil
        }

        let client = makeClient()                              // standard model (Sonnet) → effort applies
        _ = try await client.run(TuningProbeTemplate(), input: ())
        let body = try #require(StubURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["max_tokens"] as? Int == 7777)            // override honored (was hard-capped at 2048)
        let effort = (json["output_config"] as? [String: Any])?["effort"] as? String
        #expect(effort == "medium")                            // prefersFastResponse=false honored (was "low")
        #expect(json["stream"] as? Bool == true)               // every request streams (idle-bounded timeout)
    }

    /// A streamed answer cut off by the output-token budget must surface as the actionable
    /// `.responseTooLong`, not a generic parse failure — the stop reason arrives in `message_delta`.
    @Test func streamedMaxTokensStopSurfacesAsResponseTooLong() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.callCount = 0
        StubURLProtocol.responseBody = try sse(#"{"truncated…"#, stopReason: "max_tokens")
        defer { StubURLProtocol.responseBody = nil; StubURLProtocol.statusCode = 529 }

        let client = makeClient()
        await #expect(throws: LLMError.responseTooLong) {
            _ = try await client.run(HealthCheckTemplate(), input: ())
        }
    }
}

/// Overrides every per-template tuning knob, to prove they survive dispatch through the generic client.
private struct TuningProbeTemplate: PromptTemplate {
    typealias Input = Void
    typealias Output = Bool
    let id = "tuningProbe"
    var systemPrompt: String { "probe" }
    var outputJSONSchema: String { #"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}"# }
    func userMessage(for input: Void) -> String { "ping" }
    func decode(_ rawJSON: String) throws -> Bool { true }
    var maxOutputTokens: Int { 7777 }
    var prefersFastResponse: Bool { false }   // a standard-model template → adapter should choose "medium"
    var modelTier: ModelTier { .standard }
}

/// A tiny template whose schema lists its properties in NON-alphabetical order (body stays < 1 KB, so
/// it isn't gzipped and the test can read it as text).
private struct OrderedSchemaTemplate: PromptTemplate {
    let id = "orderedSchema"
    var systemPrompt: String { "Reply." }
    var outputJSONSchema: String {
        #"{"type":"object","properties":{"zeta":{"type":"string"},"alpha":{"type":"string"},"mid":{"type":"string"}},"required":["zeta","alpha","mid"],"additionalProperties":false}"#
    }
    func userMessage(for input: Void) -> String { "go" }
    func decode(_ rawJSON: String) throws -> String { rawJSON }
}
