import Foundation

public struct RobotHubMeter: Sendable, Equatable {
    /// One signal per part, in `RobotPart.allCases` order.
    public let signals: [RobotSlotState.Tone]
    public let label: String
    public let tone: RobotSlotState.Tone

    public init(signals: [RobotSlotState.Tone], label: String, tone: RobotSlotState.Tone) {
        self.signals = signals
        self.label = label
        self.tone = tone
    }
}
