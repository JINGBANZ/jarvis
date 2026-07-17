import Foundation

/// Pure timing policy for the monitor's cost-bearing screen-only fallback.
public enum ScreenRequestTiming {
    public static func fallbackDeadline(
        candidateAt: TimeInterval,
        lastVisualRequestAt: TimeInterval?,
        piggybackWait: TimeInterval,
        minimumRequestInterval: TimeInterval
    ) -> TimeInterval {
        precondition(candidateAt.isFinite)
        precondition(lastVisualRequestAt?.isFinite != false)
        precondition(piggybackWait >= 0 && piggybackWait.isFinite)
        precondition(minimumRequestInterval >= 0 && minimumRequestInterval.isFinite)

        let afterPiggybackWindow = candidateAt + piggybackWait
        guard let lastVisualRequestAt else { return afterPiggybackWindow }
        return max(
            afterPiggybackWindow,
            lastVisualRequestAt + minimumRequestInterval)
    }
}
