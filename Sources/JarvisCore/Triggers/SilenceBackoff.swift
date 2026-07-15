import Foundation

/// Schedules the proactive "are you stuck?" silence check with exponential backoff.
///
/// The first check fires after `base` seconds of quiet; while the user stays silent each successive
/// check doubles the wait (`base`, `2·base`, `4·base`, …), capped at `maxInterval`. Hearing speech
/// calls `reset()`, so the next quiet gap starts from `base` again. This avoids both over-nudging
/// (a flat short timer firing every few seconds) and under-nudging (a single one-shot timer that
/// never checks again through a long silence).
///
/// Past `idleCutoff` of continuous quiet, `shouldProbe(quietSoFar:)` turns false: the user has
/// stepped away, and each probe into the empty room still costs a full brain request. Only the
/// probe is suppressed — the caller keeps its (free, local) check running, so probing resumes as
/// soon as speech from either side restarts the quiet stretch.
public struct SilenceBackoff {
    private let base: TimeInterval
    private let maxInterval: TimeInterval
    private let idleCutoff: TimeInterval
    private var step = 0

    public init(base: TimeInterval, maxInterval: TimeInterval, idleCutoff: TimeInterval = .infinity) {
        self.base = base
        self.maxInterval = maxInterval
        self.idleCutoff = idleCutoff
    }

    /// The interval to wait before the next silence check, then advance the backoff one step.
    public mutating func next() -> TimeInterval {
        let interval = min(base * pow(2, Double(step)), maxInterval)
        step += 1
        return interval
    }

    /// Whether a check that just fired should actually probe (drive a brain request): true while
    /// the current quiet stretch is under the idle cutoff. Evaluated at FIRE time, not schedule
    /// time, so a timer that crosses the cutoff mid-wait stays quiet instead of billing one last
    /// request past the deadline.
    public func shouldProbe(quietSoFar: TimeInterval) -> Bool {
        quietSoFar < idleCutoff
    }

    /// Reset to the base interval — call when speech is heard.
    public mutating func reset() {
        step = 0
    }
}
