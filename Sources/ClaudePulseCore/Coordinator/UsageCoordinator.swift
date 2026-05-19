import Foundation
import Observation

@MainActor
@Observable
public final class UsageCoordinator {
    public private(set) var snapshot: UsageSnapshot?
    public private(set) var lastError: UsageError?
    public private(set) var isLoading = false

    private let source: any UsageSource
    private let baseInterval: TimeInterval
    private let postResetGrace: TimeInterval
    /// When the next poll may fire. Bumped forward on 429 so we don't
    /// keep hammering a rate-limited endpoint.
    private var earliestNextPoll: Date = .distantPast
    /// Session reset boundary to wake at outside the regular cadence.
    /// Cleared once we've attempted the post-reset fetch.
    private var pendingResetAt: Date?
    private var refreshTask: Task<Void, Never>?

    /// 300s default. The endpoint is per-token rate-limited at roughly
    /// ~5 requests/window (community-reverse-engineered; no published
    /// number) and the token is *shared* with the `claude` CLI — so the
    /// safe cadence is what every public statusline tool ships with.
    /// On 429 the 4× backoff below (≈ 20 min freeze) is the safety net.
    ///
    /// `postResetGrace` is how long to wait after `session.resetAt`
    /// before forcing a refresh, giving Anthropic a moment to flip the
    /// window server-side. Tests override to 0.
    public init(
        source: any UsageSource,
        refreshInterval: TimeInterval = 300,
        postResetGrace: TimeInterval = 10
    ) {
        self.source = source
        self.baseInterval = refreshInterval
        self.postResetGrace = postResetGrace
    }

    public func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshIfDue()
                let next = self.timeUntilNextPoll()
                try? await Task.sleep(nanoseconds: UInt64(next * 1_000_000_000))
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func refresh() async {
        await performRefresh()
    }

    func refreshIfDue(now: Date = Date()) async {
        if now >= earliestNextPoll {
            await performRefresh()
            return
        }
        // Clear before fetching so a transient failure doesn't loop us
        // at 1s — next successful snapshot reseeds from `session.resetAt`.
        if let pending = pendingResetAt,
           now >= pending.addingTimeInterval(postResetGrace) {
            pendingResetAt = nil
            await performRefresh()
        }
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await source.fetch()
            lastError = nil
            let now = Date()
            earliestNextPoll = now.addingTimeInterval(baseInterval)
            // Only schedule a wake if the boundary is genuinely ahead of
            // us — otherwise (server hadn't flipped yet) the regular
            // cadence will pick up the next attempt.
            pendingResetAt = snapshot?.session.resetAt.flatMap { $0 > now ? $0 : nil }
        } catch UsageError.rateLimited {
            lastError = .rateLimited
            // 429 circuit-breaker: hold off for 4× the base interval
            // (≈ 20 min at default 300s). The endpoint gives no useful
            // Retry-After, and the data windows are 5h / 7d — no value
            // in retrying tightly.
            earliestNextPoll = Date().addingTimeInterval(baseInterval * 4)
        } catch let err as UsageError {
            lastError = err
            earliestNextPoll = Date().addingTimeInterval(baseInterval)
        } catch {
            lastError = .networkError(String(describing: error))
            earliestNextPoll = Date().addingTimeInterval(baseInterval)
        }
    }

    func timeUntilNextPoll(now: Date = Date()) -> TimeInterval {
        var next = max(1, earliestNextPoll.timeIntervalSince(now))
        if let pending = pendingResetAt {
            let postReset = pending.addingTimeInterval(postResetGrace).timeIntervalSince(now)
            if postReset > 0 {
                next = min(next, postReset)
            }
        }
        return next
    }
}
