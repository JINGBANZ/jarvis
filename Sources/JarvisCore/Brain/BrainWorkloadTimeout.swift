import Foundation

public enum BrainWorkloadTimeout {
    /// Includes reasoning and streamed detail; hints can arrive before the code finishes.
    public static let liveCoaching: TimeInterval = 60

    /// Off the attempt path, so it costs no latency. Reasoning summarizers took 17-25s on real
    /// session history, and 15s failed every run.
    public static let historyCompaction: TimeInterval = 45
}
