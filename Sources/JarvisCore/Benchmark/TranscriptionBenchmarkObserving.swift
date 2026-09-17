/// Implementations must return immediately and must never invoke capture or coaching callbacks.
public protocol TranscriptionBenchmarkObserving: Sendable {
    func record(_ event: TranscriptionBenchmarkEvent)
}
