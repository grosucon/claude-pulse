import XCTest
@testable import ClaudePulseCore

/// A fake source we can program with success/failure outcomes per call.
actor FakeSource: UsageSource {
    nonisolated let name = "fake"
    private var script: [Result<UsageSnapshot, UsageError>]
    private(set) var fetchCount = 0

    init(_ outcomes: [Result<UsageSnapshot, UsageError>]) {
        self.script = outcomes
    }

    nonisolated func fetch() async throws -> UsageSnapshot {
        try await advance()
    }

    private func advance() async throws -> UsageSnapshot {
        fetchCount += 1
        guard !script.isEmpty else { throw UsageError.tokenUnavailable("test") }
        return try script.removeFirst().get()
    }
}

/// Records every append for assertion. Mirrors the FakeSource pattern.
actor FakeStore: SnapshotStore {
    private(set) var appended: [SnapshotRecord] = []

    func append(_ record: SnapshotRecord) async throws {
        appended.append(record)
    }

    func recent(limit: Int) async throws -> [SnapshotRecord] {
        Array(appended.reversed().prefix(limit))
    }
}

@MainActor
final class UsageCoordinatorTests: XCTestCase {

    func test_refresh_publishes_snapshot_on_success() async {
        let snap = makeSnapshot()
        let coord = UsageCoordinator(source: FakeSource([.success(snap)]))
        await coord.refresh()
        XCTAssertEqual(coord.snapshot, snap)
        XCTAssertNil(coord.lastError)
    }

    func test_refresh_records_error_on_failure() async {
        let coord = UsageCoordinator(source: FakeSource([.failure(.tokenUnavailable("test"))]))
        await coord.refresh()
        XCTAssertNil(coord.snapshot)
        XCTAssertEqual(coord.lastError, .tokenUnavailable("test"))
    }

    func test_refresh_keeps_previous_snapshot_on_subsequent_error() async {
        let snap = makeSnapshot()
        let coord = UsageCoordinator(source: FakeSource([.success(snap), .failure(.tokenUnavailable("test"))]))
        await coord.refresh()
        await coord.refresh()
        XCTAssertEqual(coord.snapshot, snap, "last good snapshot is retained on error")
        XCTAssertEqual(coord.lastError, .tokenUnavailable("test"))
    }

    func test_refresh_fires_after_session_reset_boundary() async {
        // resetAt is briefly in the future so the future-guard inside
        // performRefresh seeds `pendingResetAt`. We then tick `refreshIfDue`
        // from a `now` past the boundary to simulate crossing it.
        let resetAt = Date().addingTimeInterval(60)
        let snap1 = makeSnapshot(session: 41, sessionReset: resetAt)
        let snap2 = makeSnapshot(session: 0, sessionReset: resetAt.addingTimeInterval(18_000))
        let source = FakeSource([.success(snap1), .success(snap2)])
        // baseInterval 600s keeps `earliestNextPoll` far in the future so
        // only the reset-boundary path can trigger the second fetch.
        let coord = UsageCoordinator(source: source, refreshInterval: 600, postResetGrace: 0)

        await coord.refresh()
        XCTAssertEqual(coord.snapshot, snap1)

        await coord.refreshIfDue(now: resetAt.addingTimeInterval(1))

        XCTAssertEqual(coord.snapshot, snap2, "should re-fetch after session reset even within base interval")
        let count = await source.fetchCount
        XCTAssertEqual(count, 2)
    }

    func test_refresh_does_not_schedule_wake_for_past_reset() async {
        // If the server returns a resetAt that's already in the past
        // (window hadn't flipped yet), we should not re-fire the
        // post-reset path; the regular cadence picks up the next attempt.
        let pastReset = Date().addingTimeInterval(-30)
        let snap = makeSnapshot(session: 41, sessionReset: pastReset)
        let source = FakeSource([.success(snap), .success(snap)])
        let coord = UsageCoordinator(source: source, refreshInterval: 600, postResetGrace: 0)

        await coord.refresh()
        await coord.refreshIfDue(now: Date())

        let count = await source.fetchCount
        XCTAssertEqual(count, 1, "past-date resetAt must not seed pendingResetAt")
    }

    func test_refresh_appends_success_record_to_store() async throws {
        let snap = makeSnapshot(session: 42)
        let store = FakeStore()
        let coord = UsageCoordinator(source: FakeSource([.success(snap)]), store: store)

        await coord.refresh()

        let appended = await store.appended
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended.first?.outcome, .success)
        let usedPct = try XCTUnwrap(appended.first?.snapshot?.session.usedPct)
        XCTAssertEqual(usedPct, 42, accuracy: 0.001)
        XCTAssertEqual(appended.first?.sourceName, "fake")
    }

    func test_refresh_appends_error_record_with_kind() async {
        let store = FakeStore()
        let coord = UsageCoordinator(
            source: FakeSource([.failure(.rateLimited)]),
            store: store
        )

        await coord.refresh()

        let appended = await store.appended
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended.first?.outcome, .error)
        XCTAssertEqual(appended.first?.errorKind, "rateLimited")
        XCTAssertNil(appended.first?.snapshot)
    }

    func test_refresh_works_without_store() async {
        // Store is optional — app keeps running if path resolution fails.
        let snap = makeSnapshot()
        let coord = UsageCoordinator(source: FakeSource([.success(snap)]))
        await coord.refresh()
        XCTAssertEqual(coord.snapshot, snap)
    }

    func test_refresh_dedups_unchanged_usage() async {
        // Idle-poll case: same percentages, but capturedAt AND the reset
        // times drift (as the real API does). Dedup must still skip.
        let reset = Date().addingTimeInterval(3600)
        let weeklyReset = Date().addingTimeInterval(86_400)
        let snapA = makeSnapshot(session: 56, sessionReset: reset, weekly: [("All models", 15)],
                                 weeklyReset: weeklyReset, capturedAt: Date())
        let snapB = makeSnapshot(session: 56, sessionReset: reset.addingTimeInterval(45), weekly: [("All models", 15)],
                                 weeklyReset: weeklyReset.addingTimeInterval(45), capturedAt: Date().addingTimeInterval(300))
        let store = FakeStore()
        let coord = UsageCoordinator(source: FakeSource([.success(snapA), .success(snapB)]), store: store)

        await coord.refresh()
        await coord.refresh()

        let appended = await store.appended
        XCTAssertEqual(appended.count, 1, "identical usage on the second poll must not write a new record")
        XCTAssertEqual(coord.snapshot, snapB, "in-memory snapshot still advances to the latest fetch")
    }

    func test_refresh_persists_when_usage_changes() async {
        let store = FakeStore()
        let coord = UsageCoordinator(
            source: FakeSource([.success(makeSnapshot(session: 10)), .success(makeSnapshot(session: 20))]),
            store: store
        )

        await coord.refresh()
        await coord.refresh()

        let appended = await store.appended
        XCTAssertEqual(appended.count, 2, "a changed usage value writes a new record")
    }

    func test_refresh_does_not_fire_before_session_reset_boundary() async {
        let resetAt = Date().addingTimeInterval(3600)
        let snap = makeSnapshot(session: 41, sessionReset: resetAt)
        let source = FakeSource([.success(snap), .success(snap)])
        let coord = UsageCoordinator(source: source, refreshInterval: 600, postResetGrace: 0)

        await coord.refresh()
        await coord.refreshIfDue(now: Date())  // still within base interval, reset still future

        let count = await source.fetchCount
        XCTAssertEqual(count, 1, "must not refresh when neither base interval nor reset has elapsed")
    }
}
