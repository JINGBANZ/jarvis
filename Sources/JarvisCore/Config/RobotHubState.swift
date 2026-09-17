import Foundation

/// Everything the Settings hub shows, as one value.
public struct RobotHubState: Sendable, Equatable {
    public static let empty = RobotHubState(slots: [:])

    public let slots: [RobotPart: RobotSlotState]
    /// Nil until the hub knows readiness.
    public let meter: RobotHubMeter?
    /// A session is coaching with a brain target.
    public let isLive: Bool

    public init(slots: [RobotPart: RobotSlotState], meter: RobotHubMeter? = nil, isLive: Bool = false) {
        self.slots = slots
        self.meter = meter
        self.isLive = isLive
    }
}
