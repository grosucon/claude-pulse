import Foundation
@testable import ClaudePulseCore

func makeSnapshot(
    session: Double = 50,
    sessionReset: Date? = nil,
    weekly: [(label: String, used: Double)] = [("All models", 30)],
    source: String = "fake"
) -> UsageSnapshot {
    UsageSnapshot(
        session: Meter(label: "Current session", usedPct: session,
                       resetAt: sessionReset ?? Date().addingTimeInterval(3600)),
        weekly: weekly.map { Meter(label: $0.label, usedPct: $0.used,
                                   resetAt: Date().addingTimeInterval(86_400)) },
        extraUsage: nil,
        sourceName: source,
        capturedAt: Date()
    )
}
