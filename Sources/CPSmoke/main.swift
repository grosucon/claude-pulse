import Foundation
import ClaudePulseCore

@main
struct Smoke {
    static func main() async {
        do {
            let s = try await AnthropicAPISource().fetch()
            print("source: \(s.sourceName)   captured: \(s.capturedAt)")
            print("  \(s.session.label): \(fmt(s.session.usedPct))   resets at \(fmt(s.session.resetAt))")
            for m in s.weekly {
                print("  \(m.label): \(fmt(m.usedPct))   resets at \(fmt(m.resetAt))")
            }
            if let e = s.extraUsage, e.isEnabled {
                print("  extra usage: \(e.currency)\(e.usedAmount) / \(e.currency)\(e.monthlyLimit)   resets \(e.resetAt)")
            }
        } catch {
            print("ERROR: \(error)")
        }
    }

    private static func fmt(_ pct: Double) -> String { String(format: "%5.1f%%", pct) }
    private static func fmt(_ d: Date?) -> String { d.map { "\($0)" } ?? "<none>" }
}
