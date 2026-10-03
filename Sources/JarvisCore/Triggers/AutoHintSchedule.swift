import Foundation

public struct AutoHintSchedule {
    public static let interval: TimeInterval = 10
    private var nextTick: TimeInterval?

    public init() {}

    public mutating func setActive(_ active: Bool, at now: TimeInterval) {
        nextTick = active ? now + Self.interval : nil
    }

    public mutating func takeTick(at now: TimeInterval) -> Bool {
        guard let nextTick, now >= nextTick else { return false }
        self.nextTick = now + Self.interval
        return true
    }
}
