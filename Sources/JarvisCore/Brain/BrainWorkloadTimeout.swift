import Foundation

/// Response deadlines belong to the work Jarvis is waiting on, not to the provider transport.
public enum BrainWorkloadTimeout {
    /// A live coaching request should yield quickly so newer conversation is not batched behind it.
    public static let liveCoaching: TimeInterval = 15

    /// Compaction is auxiliary and lossless on failure, so it shares the same short latency ceiling.
    public static let historyCompaction: TimeInterval = 15
}
