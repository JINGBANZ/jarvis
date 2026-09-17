import Foundation

public struct SilenceBackoff {
    /// Steep so the second check lands well clear of the short first one.
    static let growth: Double = 4

    private let base: TimeInterval
    private let maxInterval: TimeInterval
    private let idleCutoff: TimeInterval
    private var step = 0

    public init(base: TimeInterval, maxInterval: TimeInterval, idleCutoff: TimeInterval = .infinity) {
        self.base = base
        self.maxInterval = maxInterval
        self.idleCutoff = idleCutoff
    }

    public mutating func next() -> TimeInterval {
        let interval = min(base * pow(Self.growth, Double(step)), maxInterval)
        step += 1
        return interval
    }

    /// Call when a check fires, not when it is scheduled, so a timer that crosses the cutoff
    /// mid-wait never bills a request. Keep checking after false; speech restarts probing.
    public func shouldProbe(quietSoFar: TimeInterval) -> Bool {
        quietSoFar < idleCutoff
    }

    /// Call when speech is heard.
    public mutating func reset() {
        step = 0
    }
}
