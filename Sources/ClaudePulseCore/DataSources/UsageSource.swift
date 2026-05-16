import Foundation

public protocol UsageSource: Sendable {
    var name: String { get }
    func fetch() async throws -> UsageSnapshot
}
