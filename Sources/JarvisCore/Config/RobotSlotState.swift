import Foundation

/// What one hub slot shows.
public struct RobotSlotState: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        case normal, live, attention
    }

    public let value: String
    /// The line under the value: the saved setting, or a live or attention line.
    public let detail: String
    public let tone: Tone
    /// Brain only: lit effort bars.
    public let level: Int?
    /// Nil until the hub knows readiness.
    public let health: RobotPartHealth?

    public init(value: String, detail: String, tone: Tone, level: Int?, health: RobotPartHealth? = nil) {
        self.value = value
        self.detail = detail
        self.tone = tone
        self.level = level
        self.health = health
    }
}
