/// Best-effort observation port installed only by the explicit transcription benchmark.
///
/// Implementations must return immediately, must not throw, and must never invoke capture or
/// coaching callbacks. Normal transcription sessions omit the port entirely.
public protocol TranscriptionBenchmarkObserving: Sendable {
    func record(_ event: TranscriptionBenchmarkEvent)
}
