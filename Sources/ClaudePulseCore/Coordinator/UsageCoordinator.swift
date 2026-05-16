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
    /// When the next poll may fire. Bumped forward on 429 so we don't
    /// keep hammering a rate-limited endpoint.
    private var earliestNextPoll: Date = .distantPast
    private var refreshTask: Task<Void, Never>?

    /// 300s default. The endpoint is per-token rate-limited at roughly
    /// ~5 requests/window (community-reverse-engineered; no published
    /// number) and the token is *shared* with the `claude` CLI — so the
    /// safe cadence is what every public statusline tool ships with.
    /// On 429 the 4× backoff below (≈ 20 min freeze) is the safety net.
    public init(source: any UsageSource, refreshInterval: TimeInterval = 300) {
        self.source = source
        self.baseInterval = refreshInterval
    }

    public func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshIfDue()
                let next = await self.timeUntilNextPoll()
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

    private func refreshIfDue() async {
        guard Date() >= earliestNextPoll else { return }
        await performRefresh()
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await source.fetch()
            lastError = nil
            earliestNextPoll = Date().addingTimeInterval(baseInterval)
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

    private func timeUntilNextPoll() -> TimeInterval {
        max(1, earliestNextPoll.timeIntervalSince(Date()))
    }
}
