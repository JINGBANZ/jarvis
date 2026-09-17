import Foundation

public struct RobotHubState: Sendable, Equatable {
    public static let empty = RobotHubState(slots: [:])

    public let slots: [RobotPart: RobotSlotState]
    /// `nil` until the hub knows readiness.
    public let meter: RobotHubMeter?
    public let isLive: Bool

    public init(slots: [RobotPart: RobotSlotState], meter: RobotHubMeter? = nil, isLive: Bool = false) {
        self.slots = slots
        self.meter = meter
        self.isLive = isLive
    }
}
