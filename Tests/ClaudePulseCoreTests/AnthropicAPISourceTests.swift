import XCTest
@testable import ClaudePulseCore

final class UsageSnapshotTests: XCTestCase {
    func test_menuBarUsedPct_returns_session_value() {
        let snap = makeSnapshot(session: 19, weekly: [("All models", 80)])
        XCTAssertEqual(snap.menuBarUsedPct, 19, "menu bar shows session, never weekly")
    }

    func test_hasSameUsage_ignores_capturedAt() {
        let session = Meter(label: "Current session", usedPct: 50, resetAt: nil)
        let weekly = [Meter(label: "All models", usedPct: 10, resetAt: nil)]
        let a = UsageSnapshot(session: session, weekly: weekly, extraUsage: nil, sourceName: "x", capturedAt: Date())
        let b = UsageSnapshot(session: session, weekly: weekly, extraUsage: nil, sourceName: "x", capturedAt: Date().addingTimeInterval(999))
        XCTAssertTrue(a.hasSameUsage(as: b), "same usage, different capturedAt → equal")
    }

    func test_hasSameUsage_detects_changed_meter() {
        let weekly = [Meter(label: "All models", usedPct: 10, resetAt: nil)]
        let a = UsageSnapshot(session: Meter(label: "s", usedPct: 50, resetAt: nil), weekly: weekly, extraUsage: nil, sourceName: "x", capturedAt: Date())
        let b = UsageSnapshot(session: Meter(label: "s", usedPct: 51, resetAt: nil), weekly: weekly, extraUsage: nil, sourceName: "x", capturedAt: a.capturedAt)
        XCTAssertFalse(a.hasSameUsage(as: b), "different usedPct is a real change")
    }

    func test_hasSameUsage_ignores_reset_time_drift() {
        // Anthropic's resets_at drifts by up to ~a minute between polls even
        // within the same window — that must NOT count as a usage change.
        let base = Date()
        let a = makeSnapshot(session: 64, sessionReset: base, weekly: [("All models", 16)],
                             weeklyReset: base.addingTimeInterval(86_400), capturedAt: base)
        let b = makeSnapshot(session: 64, sessionReset: base.addingTimeInterval(60), weekly: [("All models", 16)],
                             weeklyReset: base.addingTimeInterval(86_400 + 60), capturedAt: base.addingTimeInterval(300))
        XCTAssertTrue(a.hasSameUsage(as: b), "reset-time drift must not register as a usage change")
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

/// Module-scope so `@Sendable` runner closures can reference it without
/// capturing the (non-Sendable) XCTestCase instance.
private let goodKeychainBlob = """
{"claudeAiOauth":{"accessToken":"sk-ant-oat01-good","expiresAt":1900000000000}}

""".data(using: .utf8)!  // trailing \n simulates `security -w`

final class KeychainTokenReadFlowTests: XCTestCase {
    func test_invokes_security_with_correct_arguments() throws {
        let capture = ArgCapture()
        _ = try KeychainTokenReader.read { args in
            capture.set(args)
            return .init(stdout: goodKeychainBlob, status: 0)
        }
        XCTAssertEqual(capture.get(), ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    }

    func test_parses_identically_with_or_without_trailing_newline() throws {
        let withNL    = goodKeychainBlob                    // has the `-w` newline
        let withoutNL = goodKeychainBlob.dropLast()         // drop the 0x0A
        let a = try KeychainTokenReader.read { _ in .init(stdout: withNL,    status: 0) }
        let b = try KeychainTokenReader.read { _ in .init(stdout: Data(withoutNL), status: 0) }
        XCTAssertEqual(a.accessToken, "sk-ant-oat01-good")
        XCTAssertEqual(a, b, "trailing newline must not change the parsed token")
    }

    func test_nonzero_exit_surfaces_as_tokenUnavailable() {
        XCTAssertThrowsError(try KeychainTokenReader.read { _ in .init(stdout: Data(), status: 44) }) { error in
            guard case UsageError.tokenUnavailable(let msg) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertTrue(msg.contains("44"), "exit code should be in the message: \(msg)")
        }
    }

    func test_empty_stdout_with_zero_exit_surfaces_as_tokenUnavailable() {
        XCTAssertThrowsError(try KeychainTokenReader.read { _ in .init(stdout: Data(), status: 0) })
    }

    func test_runner_throwing_surfaces_as_tokenUnavailable() {
        struct Boom: Error {}
        XCTAssertThrowsError(try KeychainTokenReader.read { _ in throw Boom() }) { error in
            guard case UsageError.tokenUnavailable = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    func test_does_not_leak_token_into_error_message() {
        // If parse fails, the original Data must not surface in the thrown error.
        let secret = "sk-ant-oat01-LEAK-ME-IF-YOU-CAN"
        let malformed = "{\"unrelated\":\"\(secret)\"}\n".data(using: .utf8)!
        XCTAssertThrowsError(try KeychainTokenReader.read { _ in .init(stdout: malformed, status: 0) }) { error in
            XCTAssertFalse("\(error)".contains(secret), "error message must not echo token-shaped bytes")
        }
    }

    /// Sendable-safe capture box; `@Sendable` closures can't capture mutable locals.
    private final class ArgCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String]?
        func set(_ v: [String]) { lock.lock(); value = v; lock.unlock() }
        func get() -> [String]? { lock.lock(); defer { lock.unlock() }; return value }
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
