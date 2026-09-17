import Foundation

/// Routine replay-window aging is reported once; eviction during recovery keeps being reported.
public struct ReplayBufferEvictionAccumulator: Sendable {
    public enum Report: Equatable, Sendable {
        case boundedReplayWindowReached([UInt64])
        case replayCoverageLost([UInt64])
    }

    private var recoveryLossAccumulator: ReconnectBufferOverflowAccumulator
    private var reportedBoundedReplayWindow = false

    public init(recoveryLossReportInterval: TimeInterval = 5) {
        recoveryLossAccumulator = ReconnectBufferOverflowAccumulator(
            reportInterval: recoveryLossReportInterval)
    }

    public mutating func record(
        _ sequences: [UInt64],
        replayCoverageAtRisk: Bool,
        at timestamp: TimeInterval
    ) -> Report? {
        guard !sequences.isEmpty else { return nil }
        if replayCoverageAtRisk {
            guard let lost = recoveryLossAccumulator.record(sequences, at: timestamp) else {
                return nil
            }
            return .replayCoverageLost(lost)
        }
        guard !reportedBoundedReplayWindow else { return nil }
        reportedBoundedReplayWindow = true
        return .boundedReplayWindowReached(sequences)
    }

    public mutating func flush(at timestamp: TimeInterval) -> Report? {
        recoveryLossAccumulator.flush(at: timestamp).map(Report.replayCoverageLost)
    }

    public mutating func reset() {
        reportedBoundedReplayWindow = false
        recoveryLossAccumulator.reset()
    }
}
