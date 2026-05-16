import Foundation
import Security

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
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw UsageError.tokenUnavailable("Claude Code-credentials item not found in Keychain — has Claude Code been authenticated on this machine?")
        case errSecUserCanceled, errSecAuthFailed:
            throw UsageError.tokenUnavailable("Keychain access denied. Click 'Always Allow' the next time the prompt appears.")
        default:
            throw UsageError.tokenUnavailable("Keychain read failed (OSStatus \(status))")
        }
        guard let data = item as? Data else {
            throw UsageError.tokenUnavailable("Keychain item had no data")
        }
        return try parse(data)
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
}
