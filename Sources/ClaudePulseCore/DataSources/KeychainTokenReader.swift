import Foundation

/// The Claude Code CLI stores a JSON blob under generic-password service
/// "Claude Code-credentials" of shape
///   `{ "claudeAiOauth": { "accessToken", "refreshToken", "expiresAt", "scopes" } }`
/// where `expiresAt` is epoch milliseconds.
///
/// We never call `/refresh` ourselves — `refreshToken` is single-use and
/// only Claude Code knows how to rotate it. When our access token has
/// expired, we re-read the Keychain; Claude Code refreshes transparently
/// whenever the CLI runs.
public struct ClaudeCodeToken: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date

    public func isExpired(now: Date = Date(), safetyMargin: TimeInterval = 30) -> Bool {
        now.addingTimeInterval(safetyMargin) >= expiresAt
    }
}

public enum KeychainTokenReader {
    private static let service = "Claude Code-credentials"

    public static func read() throws -> ClaudeCodeToken {
        try read(runner: defaultRunner)
    }

    static func read(runner: SecurityRunner) throws -> ClaudeCodeToken {
        let result: SecurityResult
        do {
            result = try runner(["find-generic-password", "-s", service, "-w"])
        } catch {
            throw UsageError.tokenUnavailable(
                "Could not invoke /usr/bin/security: \(error.localizedDescription)"
            )
        }
        guard result.status == 0 else {
            throw UsageError.tokenUnavailable(
                "security exit \(result.status) — has `claude` been authenticated on this machine?"
            )
        }
        var bytes = result.stdout
        if bytes.last == 0x0A { bytes.removeLast() }  // `-w` appends a newline
        guard !bytes.isEmpty else {
            throw UsageError.tokenUnavailable("security returned empty output")
        }
        return try parse(bytes)
    }

    static func parse(_ data: Data) throws -> ClaudeCodeToken {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = raw["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else {
            throw UsageError.tokenUnavailable("Keychain JSON missing claudeAiOauth.accessToken")
        }
        let expiresAt: Date = {
            guard let n = oauth["expiresAt"] as? Double else {
                return Date().addingTimeInterval(60)  // unknown → assume short
            }
            // Heuristic: any timestamp ≥ 2001-09-09 in ms is ≥ 1e12, in
            // seconds is < 1e12. Inclusive boundary keeps the exact-1e12
            // value (≈ Sept 2001 in ms) parsing as milliseconds.
            return Date(timeIntervalSince1970: n >= 1_000_000_000_000 ? n / 1000 : n)
        }()
        return ClaudeCodeToken(accessToken: token, expiresAt: expiresAt)
    }

    // MARK: - Runner abstraction

    typealias SecurityRunner = @Sendable (_ arguments: [String]) throws -> SecurityResult

    struct SecurityResult: Sendable {
        let stdout: Data
        let status: Int32
    }

    /// Why we shell out instead of calling `SecItemCopyMatching` directly:
    /// `claude` rotates the OAuth token roughly every 8 hours and resets
    /// the keychain item's partition_id list when it writes, evicting any
    /// non-`apple-tool` partition. Reading via `/usr/bin/security` (which
    /// lives in the `apple-tool` partition) survives those refreshes, so
    /// the "Always Allow" prompt only ever appears once. See README.
    static let defaultRunner: SecurityRunner = { arguments in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = arguments
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError  = FileHandle.nullDevice
        proc.standardInput  = FileHandle.nullDevice
        try proc.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return SecurityResult(stdout: data, status: proc.terminationStatus)
    }
}
