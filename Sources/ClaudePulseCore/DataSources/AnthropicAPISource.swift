import Foundation

/// Talks to Anthropic's undocumented OAuth usage endpoint — the same
/// endpoint Claude Code itself calls for `/usage`. Returns the exact
/// percentages the user sees in the in-CLI panel, no estimation.
public actor AnthropicAPISource: UsageSource {
    public nonisolated let name = "anthropic-api"

    private let tokenReader: @Sendable () throws -> ClaudeCodeToken
    private let session: URLSession
    private let clock: @Sendable () -> Date
    /// Cached token; re-read only when expired or after a 401. Avoids one
    /// Keychain hit per poll tick.
    private var cachedToken: ClaudeCodeToken?

    public init(
        tokenReader: @escaping @Sendable () throws -> ClaudeCodeToken = KeychainTokenReader.read,
        session: URLSession? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tokenReader = tokenReader
        self.session = session ?? AnthropicAPISource.defaultSession
        self.clock = clock
    }

    /// Ephemeral session: no on-disk cache, no shared credential storage,
    /// no cookie persistence. Keeps the bearer token out of URLCache and
    /// out of shared `URLSession.shared` state that other code could read.
    public static let defaultSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        return URLSession(configuration: cfg)
    }()

    public func fetch() async throws -> UsageSnapshot {
        let token = try currentToken()
        do {
            let body = try await get(token: token.accessToken)
            return snapshot(from: try decode(body))
        } catch UsageError.tokenUnavailable {
            // 401 → token rejected. Invalidate cache and bubble up so the
            // next poll re-reads Keychain (Claude Code will have refreshed).
            cachedToken = nil
            throw UsageError.tokenUnavailable("token rejected — Claude Code may need to re-auth")
        }
    }

    private func currentToken() throws -> ClaudeCodeToken {
        if let t = cachedToken, !t.isExpired(now: clock()) { return t }
        let t = try tokenReader()
        cachedToken = t
        return t
    }

    // MARK: - HTTP

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private func get(token: String) async throws -> Data {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Intentionally no custom User-Agent: don't make this app trivially
        // fingerprintable for blocking, and don't broadcast "third-party
        // client" to the endpoint.

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw UsageError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.networkError("non-HTTP response")
        }
        switch http.statusCode {
        case 200: return data
        case 401: throw UsageError.tokenUnavailable("HTTP 401")
        case 429: throw UsageError.rateLimited
        default:
            throw UsageError.httpError(status: http.statusCode, body: Self.sanitisedBody(data))
        }
    }

    // MARK: - DTO + decoding

    struct ResponseDTO: Decodable {
        struct MeterDTO: Decodable {
            let utilization: Double?
            let resets_at: String?
        }
        struct ExtraUsageDTO: Decodable {
            let is_enabled: Bool
            let monthly_limit: Double?  // minor units (cents)
            let used_credits: Double?
            let utilization: Double?
            let currency: String?
        }
        let five_hour: MeterDTO?
        let seven_day: MeterDTO?
        let seven_day_opus: MeterDTO?
        let seven_day_sonnet: MeterDTO?
        let seven_day_omelette: MeterDTO?  // "Claude Design"
        let extra_usage: ExtraUsageDTO?
    }

    private static let decoder = JSONDecoder()

    /// HTTP error bodies sometimes echo request IDs, account hashes, or
    /// (in theory) parts of the request. Trim length and scrub anything
    /// that looks like an Anthropic token before letting it bubble up to
    /// the popover/tooltip.
    static func sanitisedBody(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        var text = String(raw.prefix(200))
        let tokenPattern = #"sk-ant-[A-Za-z0-9_-]+"#
        text = text.replacingOccurrences(of: tokenPattern, with: "sk-ant-***",
                                         options: .regularExpression)
        return text
    }

    /// ISO 4217 currencies have different minor-unit exponents.
    /// EUR/USD/GBP use cents (×100); JPY/KRW/CLP have no minor units (×1);
    /// BHD/JOD/KWD use thousandths (×1000). Anthropic's `monthly_limit`
    /// is in minor units, so we have to scale per currency or we report
    /// JPY users at 1% of their real cap.
    static func minorUnitScale(for code: String) -> Double {
        let pow10 = NSDecimalNumber(decimal: pow(10, fractionDigits(for: code))).doubleValue
        return pow10 > 0 ? pow10 : 1
    }

    private static func fractionDigits(for code: String) -> Int {
        guard !code.isEmpty else { return 2 }  // safest default
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = code
        // `minimumFractionDigits` defaults to the currency's ISO 4217 exponent.
        return nf.minimumFractionDigits
    }

    private func decode(_ data: Data) throws -> ResponseDTO {
        do {
            return try Self.decoder.decode(ResponseDTO.self, from: data)
        } catch {
            throw UsageError.malformedResponse(error.localizedDescription)
        }
    }

    private func snapshot(from dto: ResponseDTO) -> UsageSnapshot {
        let now = clock()
        let session = Meter(
            label: "Current session",
            usedPct: dto.five_hour?.utilization ?? 0,
            resetAt: parseDate(dto.five_hour?.resets_at)
        )

        var weekly: [Meter] = []
        if let m = dto.seven_day {
            weekly.append(Meter(label: "All models",
                                usedPct: m.utilization ?? 0,
                                resetAt: parseDate(m.resets_at)))
        }
        if let m = dto.seven_day_opus {
            weekly.append(Meter(label: "Opus only",
                                usedPct: m.utilization ?? 0,
                                resetAt: parseDate(m.resets_at)))
        }
        if let m = dto.seven_day_sonnet {
            weekly.append(Meter(label: "Sonnet only",
                                usedPct: m.utilization ?? 0,
                                resetAt: parseDate(m.resets_at)))
        }
        if let m = dto.seven_day_omelette {
            weekly.append(Meter(label: "Claude Design",
                                usedPct: m.utilization ?? 0,
                                resetAt: parseDate(m.resets_at)))
        }

        let extra: ExtraUsage? = dto.extra_usage.map { eu in
            let code = eu.currency ?? ""
            let scale = Self.minorUnitScale(for: code)
            return ExtraUsage(
                isEnabled: eu.is_enabled,
                monthlyLimit: (eu.monthly_limit ?? 0) / scale,
                usedAmount: (eu.used_credits ?? 0) / scale,
                currency: code,
                usedPct: eu.utilization,
                resetAt: TimeRounding.startOfNextMonth(after: now)
            )
        }

        return UsageSnapshot(
            session: session,
            weekly: weekly,
            extraUsage: extra,
            sourceName: name,
            capturedAt: now
        )
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let trimmed = trimToMillis(s)
        return Self.isoMs.date(from: trimmed) ?? Self.isoPlain.date(from: trimmed)
    }

    /// Anthropic returns microsecond precision (e.g. `…917651+00:00`);
    /// Foundation's parser only handles up to milliseconds. Trim the
    /// fractional part to 3 digits, leaving the timezone intact.
    private func trimToMillis(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        let afterDot = s.index(after: dot)
        guard let tzStart = s[afterDot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
        else { return s }
        let fractional = s[afterDot..<tzStart]
        let truncated = fractional.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)
        return String(s[..<afterDot] + truncated + s[tzStart...])
    }

    nonisolated(unsafe) private static let isoMs: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
