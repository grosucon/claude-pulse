import Foundation

enum TimeRounding {
    /// First moment of the next calendar month, in local time.
    /// Used for the `extra_usage` monthly reset, which Anthropic's panel
    /// labels "Resets Jun 1" etc.
    static func startOfNextMonth(after date: Date) -> Date {
        let comps = DateComponents(day: 1, hour: 0, minute: 0)
        return Calendar(identifier: .gregorian).nextDate(
            after: date,
            matching: comps,
            matchingPolicy: .nextTime
        ) ?? date.addingTimeInterval(31 * 86_400)
    }
}
