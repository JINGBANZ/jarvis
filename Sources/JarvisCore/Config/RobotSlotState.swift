import Foundation

public struct RobotSlotState: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        case normal, live, attention
    }

    public let value: String
    public let detail: String
    public let tone: Tone
    /// Brain only.
    public let level: Int?
    /// `nil` until the hub knows readiness.
    public let health: RobotPartHealth?

    public init(value: String, detail: String, tone: Tone, level: Int?, health: RobotPartHealth? = nil) {
        self.value = value
        self.detail = detail
        self.tone = tone
        self.level = level
        self.health = health
    }
}
