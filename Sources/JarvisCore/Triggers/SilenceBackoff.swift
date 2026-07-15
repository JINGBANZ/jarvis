import Foundation

/// Schedules the proactive "are you stuck?" silence check with exponential backoff.
///
/// The first check fires after `base` seconds of quiet; while the user stays silent each successive
/// check doubles the wait (`base`, `2·base`, `4·base`, …), capped at `maxInterval`. Hearing speech
/// calls `reset()`, so the next quiet gap starts from `base` again. This avoids both over-nudging
/// (a flat short timer firing every few seconds) and under-nudging (a single one-shot timer that
/// never checks again through a long silence).
///
/// Past `idleCutoff` of continuous quiet, `next(quietSoFar:)` returns nil: the user has stepped
/// away, and each probe into the empty room still costs a full brain request. Speech re-arms via
/// `reset()` as usual.
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

    /// The interval to wait before the next silence check (advancing the backoff one step) — or nil
    /// once `quietSoFar` (how long the user has already been quiet) reaches the idle cutoff, meaning:
    /// stop probing until speech resumes.
    public mutating func next(quietSoFar: TimeInterval = 0) -> TimeInterval? {
        guard quietSoFar < idleCutoff else { return nil }
        let interval = min(base * pow(2, Double(step)), maxInterval)
        step += 1
        return interval
    }

    /// Reset to the base interval — call when speech is heard.
    public mutating func reset() {
        step = 0
    }
}
