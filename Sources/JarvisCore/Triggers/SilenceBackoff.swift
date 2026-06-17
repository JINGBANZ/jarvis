import Foundation

/// Schedules the proactive "are you stuck?" silence check with exponential backoff.
///
/// The first check fires after `base` seconds of quiet; while the user stays silent each successive
/// check doubles the wait (`base`, `2·base`, `4·base`, …), capped at `maxInterval`. Hearing speech
/// calls `reset()`, so the next quiet gap starts from `base` again. This avoids both over-nudging
/// (a flat short timer firing every few seconds) and under-nudging (a single one-shot timer that
/// never checks again through a long silence).
public struct SilenceBackoff {
    private let base: TimeInterval
    private let maxInterval: TimeInterval
    private var step = 0

    public init(base: TimeInterval, maxInterval: TimeInterval) {
        self.base = base
        self.maxInterval = maxInterval
    }

    /// The interval to wait before the next silence check, then advance the backoff one step.
    public mutating func next() -> TimeInterval {
        let interval = min(base * pow(2, Double(step)), maxInterval)
        step += 1
        return interval
    }

    /// Reset to the base interval — call when speech is heard.
    public mutating func reset() {
        step = 0
    }
}
