import Foundation

public struct RobotHubMeter: Sendable, Equatable {
    /// One flag per part, in `RobotPart.allCases` order.
    public let ready: [Bool]
    public let label: String
    public let tone: RobotSlotState.Tone

    public init(ready: [Bool], label: String, tone: RobotSlotState.Tone) {
        self.ready = ready
        self.label = label
        self.tone = tone
    }
}
