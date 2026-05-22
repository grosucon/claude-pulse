import Foundation

/// JSONL on-disk implementation of `SnapshotStore`. Lives in
/// `~/Library/Application Support/ClaudePulse/` by default so it survives
/// `./scripts/install.sh` (which only touches `~/Applications/`) and the
/// standard Finder drag-to-Trash of the bundle. AppCleaner-style
/// uninstallers will still find it.
///
/// Retention: the file is capped at `maxRecords` lines. A compaction pass
/// (read tail, atomic rewrite) runs every `compactionInterval` appends and
/// once on the first append after launch, so a single record costs one
/// append almost always and the file can't grow without bound.
public actor JSONLSnapshotStore: SnapshotStore {
    private static let newline: UInt8 = 0x0A

    private let url: URL
    private let fileManager: FileManager
    private let maxRecords: Int
    private let compactionInterval: Int
    private var appendsSinceCompaction = 0
    /// Forces one compaction check on the first append so a large
    /// pre-existing file (e.g. one written before retention existed) gets
    /// trimmed promptly instead of waiting a full interval.
    private var hasCompactedSinceLaunch = false
    nonisolated private let encoder: JSONEncoder
    nonisolated private let decoder: JSONDecoder

    /// `maxRecords` default 10_000 ≈ 35 days at the 300s poll cadence —
    /// comfortably covers every downstream window (burn-rate ~24h,
    /// sparkline ~week, retro ~2 weeks). At ~500 B/record that's ~5 MB.
    public init(
        url: URL,
        fileManager: FileManager = .default,
        maxRecords: Int = 10_000,
        compactionInterval: Int = 500
    ) {
        self.url = url
        self.fileManager = fileManager
        self.maxRecords = max(1, maxRecords)
        self.compactionInterval = max(1, compactionInterval)

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        // Sorted keys = byte-identical encoding across runs, so diffs
        // and assertions stay sane.
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func append(_ record: SnapshotRecord) async throws {
        var data = try encoder.encode(record)
        data.append(Self.newline)

        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        // createFile truncates an existing file, so only call it when the
        // file is absent — otherwise every append would wipe the log.
        if !fileManager.fileExists(atPath: url.path) {
            // 0o600: keep the usage history readable only by the owning user.
            fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        // fsync — a crashed process must not lose a record we already
        // returned success for. Cost is negligible at 300s cadence.
        try handle.synchronize()

        appendsSinceCompaction += 1
        if !hasCompactedSinceLaunch || appendsSinceCompaction >= compactionInterval {
            hasCompactedSinceLaunch = true
            appendsSinceCompaction = 0
            try? compact()
        }
    }

    public func recent(limit: Int) async throws -> [SnapshotRecord] {
        guard limit > 0, fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }

        var records: [SnapshotRecord] = []
        let tail = lines(in: data).suffix(limit)
        records.reserveCapacity(tail.count)
        for line in tail {
            // Skip malformed lines instead of failing the whole read —
            // a forward-schema line should never break older readers.
            if let rec = try? decoder.decode(SnapshotRecord.self, from: Data(line)) {
                records.append(rec)
            }
        }
        return records.reversed()
    }

    private func lines(in data: Data) -> [Data.SubSequence] {
        data.split(separator: Self.newline, omittingEmptySubsequences: true)
    }

    public static func defaultLocation(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appending(component: "ClaudePulse", directoryHint: .isDirectory)
            .appending(component: "snapshots.jsonl", directoryHint: .notDirectory)
    }

    /// Rewrite the file keeping only the most recent `maxRecords` lines.
    /// No-op when the file is already within bounds.
    private func compact() throws {
        let data = try Data(contentsOf: url)
        let all = lines(in: data)
        guard all.count > maxRecords else { return }

        // The kept lines are a contiguous, newline-terminated suffix of the
        // original bytes — slice from the first one's offset rather than
        // rebuilding line by line.
        guard let first = all.suffix(maxRecords).first else { return }
        try data[first.startIndex...].write(to: url, options: .atomic)
        // .atomic writes a fresh file, dropping our 0o600 — restore it.
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
