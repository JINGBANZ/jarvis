import Foundation

/// Response deadlines belong to the work Jarvis is waiting on, not to the provider transport.
public enum BrainWorkloadTimeout {
    /// A live coaching request should yield quickly so newer conversation is not batched behind it.
    public static let liveCoaching: TimeInterval = 15

    /// Compaction runs off the attempt path, so its budget costs no coaching latency and only needs
    /// to be long enough to finish. A reasoning summarizer measured 17-25s on real session history;
    /// the previous 15s ceiling could not be met and failed every run, letting history grow unbounded.
    public static let historyCompaction: TimeInterval = 45
}
