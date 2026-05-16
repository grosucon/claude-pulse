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
}
