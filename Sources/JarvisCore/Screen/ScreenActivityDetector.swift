import Foundation

/// Coalesces frame-level screen activity into one stable change after a quiet interval.
///
/// Callers provide monotonic timestamps and classify each frame as either a content change or idle.
/// Significant changes start or restart a candidate; only an idle observation after `quiescenceInterval`
/// reports it. Candidate IDs make asynchronous acknowledgement/rejection safe when a newer visual
/// state appears before an older delivery finishes.
public struct ScreenActivityDetector: Sendable {
    public struct CandidateID: Hashable, Sendable {
        fileprivate let rawValue: UInt64
    }

    public enum FrameSignal: Sendable, Equatable {
        case contentChanged(changedAreaRatio: Double)
        case idle
    }

    public enum ObservationResult: Sendable, Equatable {
        case idle
        case ignored
        case waitingForQuiescence
        case stableChange(CandidateID)
        case awaitingAcknowledgement(CandidateID)
    }

    private enum DeliveryState: Sendable, Equatable {
        case collecting
        case awaitingAcknowledgement
    }

    private struct Candidate: Sendable {
        let id: CandidateID
        let lastSignificantChangeAt: TimeInterval
        var deliveryState: DeliveryState
    }

    private let quiescenceInterval: TimeInterval
    private let minimumChangedAreaRatio: Double
    private var candidate: Candidate?
    private var lastObservationAt: TimeInterval?
    private var nextCandidateRawValue: UInt64 = 1

    public init(quiescenceInterval: TimeInterval, minimumChangedAreaRatio: Double) {
        precondition(quiescenceInterval >= 0 && quiescenceInterval.isFinite,
                     "Quiescence interval must be finite and nonnegative")
        precondition((0...1).contains(minimumChangedAreaRatio),
                     "Minimum changed-area ratio must be between zero and one")
        self.quiescenceInterval = quiescenceInterval
        self.minimumChangedAreaRatio = minimumChangedAreaRatio
    }

    public mutating func observe(_ signal: FrameSignal,
                                 at timestamp: TimeInterval) -> ObservationResult {
        precondition(timestamp.isFinite, "Observation timestamp must be finite")
        if let lastObservationAt {
            precondition(timestamp >= lastObservationAt,
                         "Observation timestamps must be monotonic")
        }
        lastObservationAt = timestamp

        switch signal {
        case .contentChanged(let changedAreaRatio):
            precondition((0...1).contains(changedAreaRatio),
                         "Changed-area ratio must be between zero and one")
            guard changedAreaRatio >= minimumChangedAreaRatio else { return .ignored }

            candidate = Candidate(
                id: makeCandidateID(),
                lastSignificantChangeAt: timestamp,
                deliveryState: .collecting)
            return .waitingForQuiescence

        case .idle:
            guard var candidate else { return .idle }
            if candidate.deliveryState == .awaitingAcknowledgement {
                return .awaitingAcknowledgement(candidate.id)
            }
            guard timestamp - candidate.lastSignificantChangeAt >= quiescenceInterval else {
                return .waitingForQuiescence
            }

            candidate.deliveryState = .awaitingAcknowledgement
            self.candidate = candidate
            return .stableChange(candidate.id)
        }
    }

    /// Commits the reported candidate. Returns false for a stale ID or a candidate not yet reported.
    @discardableResult
    public mutating func acknowledge(_ id: CandidateID) -> Bool {
        guard candidate?.id == id,
              candidate?.deliveryState == .awaitingAcknowledgement else { return false }
        candidate = nil
        return true
    }

    /// Re-arms a failed delivery without requiring another content change or quiet interval.
    @discardableResult
    public mutating func reject(_ id: CandidateID) -> Bool {
        guard candidate?.id == id,
              candidate?.deliveryState == .awaitingAcknowledgement else { return false }
        candidate?.deliveryState = .collecting
        return true
    }

    public mutating func reset() {
        candidate = nil
        lastObservationAt = nil
    }

    private mutating func makeCandidateID() -> CandidateID {
        let id = CandidateID(rawValue: nextCandidateRawValue)
        nextCandidateRawValue &+= 1
        return id
    }
}
