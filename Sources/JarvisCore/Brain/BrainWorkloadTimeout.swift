import Foundation

public enum BrainWorkloadTimeout {
    /// Short, so newer conversation is not batched behind a slow request.
    public static let liveCoaching: TimeInterval = 15

    /// Off the attempt path, so it costs no latency. Reasoning summarizers took 17-25s on real
    /// session history, and 15s failed every run.
    public static let historyCompaction: TimeInterval = 45
}
