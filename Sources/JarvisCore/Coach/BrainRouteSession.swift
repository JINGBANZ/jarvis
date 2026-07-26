import Foundation

/// Pure session-local cursor and health policy for an ordered provider route.
///
/// The route only moves forward. Temporary/unknown attempt failures exhaust a target on the third
/// consecutive failure; a proven permanent failure exhausts it immediately. Success clears only
/// the active target's count and never returns to an earlier target.
struct BrainRouteSession: Sendable, Equatable {
    static let failuresPerTarget = 3

    enum FailureTransition: Sendable, Equatable {
        case stay(failureCount: Int)
        case advanced(from: Int, to: Int)
        case exhausted(last: Int)
    }

    private(set) var activeIndex = 0
    private(set) var consecutiveFailures = 0
    let targetCount: Int

    init(targetCount: Int) {
        precondition(targetCount > 0)
        self.targetCount = targetCount
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    mutating func recordFailure(_ disposition: BrainFailure.Disposition) -> FailureTransition {
        consecutiveFailures += 1
        let targetIsExhausted = disposition == .permanent
            || consecutiveFailures >= Self.failuresPerTarget
        guard targetIsExhausted else {
            return .stay(failureCount: consecutiveFailures)
        }
        return advance()
    }

    /// Skip a target that cannot be constructed without charging a synthetic provider attempt.
    mutating func skipUnavailable() -> FailureTransition {
        advance()
    }

    private mutating func advance() -> FailureTransition {
        let previous = activeIndex
        consecutiveFailures = 0
        guard activeIndex + 1 < targetCount else {
            return .exhausted(last: previous)
        }
        activeIndex += 1
        return .advanced(from: previous, to: activeIndex)
    }
}
