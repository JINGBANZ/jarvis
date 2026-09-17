import Foundation

/// Reports the first eviction at once, then periodically, so a long overflow can't log one line per
/// 10 ms chunk.
public struct ReconnectBufferOverflowAccumulator: Sendable {
    private let reportInterval: TimeInterval
    private var lastReportAt: TimeInterval?
    private var pendingSequences: [UInt64] = []

    public init(reportInterval: TimeInterval = 5) {
        precondition(reportInterval >= 0)
        self.reportInterval = reportInterval
    }

    public mutating func record(_ sequences: [UInt64], at timestamp: TimeInterval) -> [UInt64]? {
        guard !sequences.isEmpty else { return nil }
        pendingSequences += sequences
        guard lastReportAt == nil || timestamp - lastReportAt! >= reportInterval else { return nil }
        return emit(at: timestamp)
    }

    public mutating func flush(at timestamp: TimeInterval) -> [UInt64]? {
        guard !pendingSequences.isEmpty else { return nil }
        return emit(at: timestamp)
    }

    public mutating func reset() {
        lastReportAt = nil
        pendingSequences.removeAll(keepingCapacity: false)
    }

    private mutating func emit(at timestamp: TimeInterval) -> [UInt64] {
        let sequences = pendingSequences
        pendingSequences.removeAll(keepingCapacity: true)
        lastReportAt = timestamp
        return sequences
    }
}
