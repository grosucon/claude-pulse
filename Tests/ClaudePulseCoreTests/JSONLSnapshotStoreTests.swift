import XCTest
@testable import ClaudePulseCore

final class JSONLSnapshotStoreTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudePulseTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try await super.tearDown()
    }

    private func storeURL() -> URL {
        tempRoot.appendingPathComponent("snapshots.jsonl", isDirectory: false)
    }

    private func successRecord(session: Double = 50) -> SnapshotRecord {
        let snap = makeSnapshot(session: session)
        return .success(capturedAt: snap.capturedAt, sourceName: snap.sourceName, snapshot: snap)
    }

    func test_round_trip_preserves_record() async throws {
        let store = JSONLSnapshotStore(url: storeURL())
        try await store.append(successRecord(session: 42))
        let recent = try await store.recent(limit: 10)

        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.outcome, .success)
        let usedPct = try XCTUnwrap(recent.first?.snapshot?.session.usedPct)
        XCTAssertEqual(usedPct, 42, accuracy: 0.001)
    }

    func test_append_is_append_only_and_returns_newest_first() async throws {
        let store = JSONLSnapshotStore(url: storeURL())
        for pct in [10.0, 20.0, 30.0] {
            try await store.append(successRecord(session: pct))
        }

        let recent = try await store.recent(limit: 10)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.map { $0.snapshot?.session.usedPct ?? 0 }, [30, 20, 10],
                       "newest-first ordering")
    }

    func test_recent_caps_at_limit() async throws {
        let store = JSONLSnapshotStore(url: storeURL())
        for i in 0..<100 {
            try await store.append(successRecord(session: Double(i)))
        }
        let recent = try await store.recent(limit: 5)
        XCTAssertEqual(recent.count, 5)
        XCTAssertEqual(recent.first?.snapshot?.session.usedPct, 99, "newest first")
        XCTAssertEqual(recent.last?.snapshot?.session.usedPct, 95)
    }

    func test_recent_on_missing_file_returns_empty() async throws {
        let store = JSONLSnapshotStore(url: storeURL())
        let recent = try await store.recent(limit: 10)
        XCTAssertEqual(recent, [])
    }

    func test_append_bootstraps_missing_parent_directory() async throws {
        let nested = tempRoot
            .appendingPathComponent("deeply", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("snapshots.jsonl", isDirectory: false)
        let store = JSONLSnapshotStore(url: nested)

        try await store.append(successRecord())

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path),
                      "append should create parent directories on first write")
    }

    func test_error_record_round_trip_carries_kind() async throws {
        let store = JSONLSnapshotStore(url: storeURL())
        let r = SnapshotRecord.error(capturedAt: Date(), sourceName: "fake", kind: "rateLimited")

        try await store.append(r)
        let recent = try await store.recent(limit: 1)

        XCTAssertEqual(recent.first?.outcome, .error)
        XCTAssertEqual(recent.first?.errorKind, "rateLimited")
        XCTAssertNil(recent.first?.snapshot)
    }

    func test_one_record_per_line() async throws {
        let store = JSONLSnapshotStore(url: storeURL())
        for i in 0..<3 {
            try await store.append(successRecord(session: Double(i)))
        }

        let bytes = try Data(contentsOf: storeURL())
        let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3, "JSONL invariant: one record per line, trailing LF")
        XCTAssertEqual(bytes.last, 0x0A, "every record ends with LF")
    }

    func test_retention_trims_to_max_records() async throws {
        // Tight cap + check-every-append so retention is exercised quickly.
        let store = JSONLSnapshotStore(url: storeURL(), maxRecords: 5, compactionInterval: 1)
        for i in 0..<10 {
            try await store.append(successRecord(session: Double(i)))
        }

        let bytes = try Data(contentsOf: storeURL())
        let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: true)
        XCTAssertLessThanOrEqual(lines.count, 5, "file is capped at maxRecords")

        let recent = try await store.recent(limit: 100)
        XCTAssertEqual(recent.map { $0.snapshot?.session.usedPct ?? -1 }, [9, 8, 7, 6, 5],
                       "retention keeps the newest records, drops the oldest")
    }

    func test_retention_preserves_file_permissions() async throws {
        let store = JSONLSnapshotStore(url: storeURL(), maxRecords: 3, compactionInterval: 1)
        for i in 0..<6 {
            try await store.append(successRecord(session: Double(i)))
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: storeURL().path)
        let perms = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perms.int16Value, 0o600, "compaction rewrite must restore 0o600")
    }

    /// Tripwire: tokens must never leak into the on-disk log. The bearer
    /// token never enters `UsageSnapshot` — this pins the invariant so any
    /// future regression (e.g. adding `Authorization` to a snapshot field)
    /// fails loudly.
    func test_does_not_leak_bearer_token_to_disk() async throws {
        let store = JSONLSnapshotStore(url: storeURL())
        try await store.append(successRecord())

        let bytes = try Data(contentsOf: storeURL())
        let text = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("sk-ant-"),
                       "on-disk log must never contain an Anthropic token literal")
        XCTAssertFalse(text.contains("Bearer "),
                       "on-disk log must never contain Authorization header text")
    }

    func test_new_store_creates_file_with_owner_only_permissions() async throws {
        let store = JSONLSnapshotStore(url: storeURL())
        try await store.append(successRecord())

        let attrs = try FileManager.default.attributesOfItem(atPath: storeURL().path)
        let perms = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perms.int16Value, 0o600)
    }
}
