import Foundation

public protocol SnapshotStore: Sendable {
    func append(_ record: SnapshotRecord) async throws
    /// Newest-first, capped at `limit`. Caller-bounded so we never load
    /// the whole file just to read the last few entries.
    func recent(limit: Int) async throws -> [SnapshotRecord]
}

public struct SnapshotRecord: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable { case success, error }

    public let schemaVersion: Int
    public let capturedAt: Date
    public let outcome: Outcome
    public let sourceName: String
    public let snapshot: UsageSnapshot?
    public let errorKind: String?

    public init(
        schemaVersion: Int = 1,
        capturedAt: Date,
        outcome: Outcome,
        sourceName: String,
        snapshot: UsageSnapshot? = nil,
        errorKind: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.capturedAt = capturedAt
        self.outcome = outcome
        self.sourceName = sourceName
        self.snapshot = snapshot
        self.errorKind = errorKind
    }

    public static func success(
        capturedAt: Date,
        sourceName: String,
        snapshot: UsageSnapshot
    ) -> SnapshotRecord {
        SnapshotRecord(
            capturedAt: capturedAt,
            outcome: .success,
            sourceName: sourceName,
            snapshot: snapshot
        )
    }

    public static func error(
        capturedAt: Date,
        sourceName: String,
        kind: String
    ) -> SnapshotRecord {
        SnapshotRecord(
            capturedAt: capturedAt,
            outcome: .error,
            sourceName: sourceName,
            errorKind: kind
        )
    }
}
