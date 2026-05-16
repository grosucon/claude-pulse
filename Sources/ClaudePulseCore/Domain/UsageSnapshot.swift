import Foundation

/// A single named meter from Anthropic's `/api/oauth/usage` endpoint —
/// the panel rows like "All models", "Sonnet only", "Claude Design".
public struct Meter: Sendable, Equatable {
    public let label: String
    public let usedPct: Double
    /// When the window resets. nil when the meter has never been used
    /// (Anthropic returns `resets_at: null` in that case).
    public let resetAt: Date?

    public init(label: String, usedPct: Double, resetAt: Date?) {
        self.label = label
        self.usedPct = usedPct
        self.resetAt = resetAt
    }
}

/// "Extra usage" — pay-as-you-go credits beyond the subscription. Returned
/// by the API as a single object; resets on the first of every month.
public struct ExtraUsage: Sendable, Equatable {
    public let isEnabled: Bool
    /// Monthly cap, normalised to whole currency units (the API returns
    /// minor units / cents).
    public let monthlyLimit: Double
    /// Currency consumed this period, whole units.
    public let usedAmount: Double
    /// 3-letter currency code (e.g. "EUR", "USD"). Empty string if unknown.
    public let currency: String
    /// 0...100; nil when nothing has been spent yet.
    public let usedPct: Double?
    /// First of next month, local time.
    public let resetAt: Date

    public init(
        isEnabled: Bool, monthlyLimit: Double, usedAmount: Double,
        currency: String, usedPct: Double?, resetAt: Date
    ) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedAmount = usedAmount
        self.currency = currency
        self.usedPct = usedPct
        self.resetAt = resetAt
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    /// 5-hour session block, %% used + reset.
    public let session: Meter
    /// Weekly meters: "All models" first, then any per-family sub-caps
    /// the API exposes (Sonnet, Opus, Claude Design / Omelette). Skipped
    /// when the API returns null for that bucket.
    public let weekly: [Meter]
    public let extraUsage: ExtraUsage?

    public let sourceName: String
    public let capturedAt: Date

    public init(
        session: Meter,
        weekly: [Meter],
        extraUsage: ExtraUsage?,
        sourceName: String,
        capturedAt: Date
    ) {
        self.session = session
        self.weekly = weekly
        self.extraUsage = extraUsage
        self.sourceName = sourceName
        self.capturedAt = capturedAt
    }

    /// What the menu bar shows: the session %% used.
    public var menuBarUsedPct: Double { session.usedPct }
}

public enum UsageError: Error, Sendable, Equatable {
    /// No usable Claude Code OAuth token in Keychain.
    case tokenUnavailable(String)
    /// HTTP-level failure from the usage endpoint.
    case httpError(status: Int, body: String)
    /// Anthropic 429'd us. Cache and back off; don't retry tightly.
    case rateLimited
    /// Network or DNS failure.
    case networkError(String)
    /// Response decoded but didn't carry the fields we need.
    case malformedResponse(String)
}
