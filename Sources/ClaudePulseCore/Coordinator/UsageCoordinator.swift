import Foundation
import Observation

@MainActor
@Observable
public final class UsageCoordinator {
    public private(set) var snapshot: UsageSnapshot?
    public private(set) var lastError: UsageError?
    public private(set) var isLoading = false

    private let source: any UsageSource
    private let store: (any SnapshotStore)?
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
    ///
    /// `store` is optional and best-effort: write failures are swallowed
    /// so a disk problem can't take down the live snapshot.
    public init(
        source: any UsageSource,
        store: (any SnapshotStore)? = nil,
        refreshInterval: TimeInterval = 300,
        postResetGrace: TimeInterval = 10
    ) {
        self.source = source
        self.store = store
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
            let snap = try await source.fetch()
            let previous = snapshot
            snapshot = snap
            lastError = nil
            let now = Date()
            earliestNextPoll = now.addingTimeInterval(baseInterval)
            // Only schedule a wake if the boundary is genuinely ahead of
            // us — otherwise (server hadn't flipped yet) the regular
            // cadence will pick up the next attempt.
            pendingResetAt = snap.session.resetAt.flatMap { $0 > now ? $0 : nil }
            // Dedup: only persist when usage actually moved. Idle polls
            // produce snapshots identical bar the timestamp; writing each
            // one just bloats the log.
            let changed = previous.map { !$0.hasSameUsage(as: snap) } ?? true
            if changed {
                await persist(.success(
                    capturedAt: snap.capturedAt,
                    sourceName: snap.sourceName,
                    snapshot: snap
                ))
            }
        } catch {
            let usageError = (error as? UsageError) ?? .networkError(String(describing: error))
            lastError = usageError
            // 429 circuit-breaker: hold off 4× the base interval (≈ 20 min
            // at 300s). The endpoint gives no useful Retry-After and the
            // windows are 5h / 7d — no value retrying tightly. Everything
            // else retries at the base cadence.
            let backoff = usageError == .rateLimited ? baseInterval * 4 : baseInterval
            earliestNextPoll = Date().addingTimeInterval(backoff)
            await persist(.error(capturedAt: Date(), sourceName: source.name, kind: usageError.kind))
        }
    }

    private func persist(_ record: SnapshotRecord) async {
        guard let store else { return }
        try? await store.append(record)
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
