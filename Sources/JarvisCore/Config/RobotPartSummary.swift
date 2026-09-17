import Foundation

/// What one part's saved settings say on its hub slot.
public struct RobotPartSummary: Sendable, Equatable {
    public let value: String
    /// Short upper-case line under the value.
    public let detail: String
    /// Brain only: how many of the three effort bars are lit, None 0 through High 3.
    public let level: Int?

    public init(value: String, detail: String, level: Int? = nil) {
        self.value = value
        self.detail = detail
        self.level = level
    }
}
