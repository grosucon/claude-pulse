import XCTest
@testable import ClaudePulseCore

final class UsageSnapshotTests: XCTestCase {
    func test_menuBarUsedPct_returns_session_value() {
        let snap = makeSnapshot(session: 19, weekly: [("All models", 80)])
        XCTAssertEqual(snap.menuBarUsedPct, 19, "menu bar shows session, never weekly")
    }
}

final class KeychainTokenParseTests: XCTestCase {
    func test_parses_current_claude_code_blob_shape() throws {
        let payload = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-abc",
            "refreshToken": "sk-ant-ort01-xyz",
            "expiresAt": 1779999999000,
            "scopes": ["user:inference"]
          }
        }
        """.data(using: .utf8)!
        let token = try KeychainTokenReader.parse(payload)
        XCTAssertEqual(token.accessToken, "sk-ant-oat01-abc")
        XCTAssertFalse(token.isExpired(), "expiresAt is in 2026")
    }

    func test_throws_when_accessToken_missing() {
        let payload = "{\"claudeAiOauth\": {}}".data(using: .utf8)!
        XCTAssertThrowsError(try KeychainTokenReader.parse(payload))
    }

    func test_tolerates_seconds_or_milliseconds_in_expiresAt() throws {
        let asMs  = "{\"claudeAiOauth\":{\"accessToken\":\"x\",\"expiresAt\":1900000000000}}".data(using: .utf8)!
        let asSec = "{\"claudeAiOauth\":{\"accessToken\":\"x\",\"expiresAt\":1900000000}}".data(using: .utf8)!
        let a = try KeychainTokenReader.parse(asMs)
        let b = try KeychainTokenReader.parse(asSec)
        XCTAssertEqual(a.expiresAt.timeIntervalSince1970, b.expiresAt.timeIntervalSince1970, accuracy: 1,
                       "ms and seconds should normalise to the same Date")
    }
}

final class AnthropicAPISourceDecodeTests: XCTestCase {

    /// Real response shape captured on the author's account 2026-05-16.
    /// Anonymised: percentages and timestamps left in (not sensitive).
    private let sampleJSON = """
    {
      "five_hour": { "utilization": 19.0, "resets_at": "2026-05-16T11:39:59.917651+00:00" },
      "seven_day": { "utilization": 3.0,  "resets_at": "2026-05-19T21:59:59.917673+00:00" },
      "seven_day_oauth_apps": null,
      "seven_day_opus": null,
      "seven_day_sonnet": { "utilization": 0.0, "resets_at": null },
      "seven_day_omelette": { "utilization": 0.0, "resets_at": null },
      "tangelo": null,
      "iguana_necktie": null,
      "extra_usage": {
        "is_enabled": true,
        "monthly_limit": 4000,
        "used_credits": 0.0,
        "utilization": null,
        "currency": "EUR",
        "disabled_reason": null
      }
    }
    """.data(using: .utf8)!

    func test_decodes_real_response_into_session_and_weekly_meters() async throws {
        let source = AnthropicAPISource(
            tokenReader: { ClaudeCodeToken(accessToken: "x", expiresAt: Date().addingTimeInterval(3600)) },
            session: stubbedSession(returning: sampleJSON, status: 200),
            clock: { ISO8601DateFormatter().date(from: "2026-05-16T08:00:00Z")! }
        )
        let snap = try await source.fetch()
        XCTAssertEqual(snap.sourceName, "anthropic-api")
        XCTAssertEqual(snap.session.usedPct, 19, accuracy: 0.01)
        XCTAssertNotNil(snap.session.resetAt)

        XCTAssertEqual(snap.weekly.map(\.label), ["All models", "Sonnet only", "Claude Design"])
        XCTAssertEqual(snap.weekly[0].usedPct, 3, accuracy: 0.01)
        XCTAssertEqual(snap.weekly[1].usedPct, 0, accuracy: 0.01)
        XCTAssertNil(snap.weekly[1].resetAt, "sonnet never used -> null reset")

        let extra = try XCTUnwrap(snap.extraUsage)
        XCTAssertTrue(extra.isEnabled)
        XCTAssertEqual(extra.monthlyLimit, 40, accuracy: 0.01, "cents -> EUR 40.00")
        XCTAssertEqual(extra.usedAmount, 0, accuracy: 0.01)
        XCTAssertEqual(extra.currency, "EUR")
    }

    func test_401_surfaces_as_tokenUnavailable() async {
        let source = AnthropicAPISource(
            tokenReader: { ClaudeCodeToken(accessToken: "x", expiresAt: Date().addingTimeInterval(3600)) },
            session: stubbedSession(returning: Data(), status: 401)
        )
        do { _ = try await source.fetch(); XCTFail("expected throw") }
        catch UsageError.tokenUnavailable { }
        catch { XCTFail("got \(error)") }
    }

    func test_429_surfaces_as_rateLimited() async {
        let source = AnthropicAPISource(
            tokenReader: { ClaudeCodeToken(accessToken: "x", expiresAt: Date().addingTimeInterval(3600)) },
            session: stubbedSession(returning: Data(), status: 429)
        )
        do { _ = try await source.fetch(); XCTFail("expected throw") }
        catch UsageError.rateLimited { }
        catch { XCTFail("got \(error)") }
    }

    // MARK: - URLSession stub

    private func stubbedSession(returning data: Data, status: Int) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.next = (data, status)
        return URLSession(configuration: config)
    }
}

// MARK: - URLProtocol stub

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var next: (Data, Int) = (Data(), 200)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (data, status) = Self.next
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
