/// Optional capabilities supplied only while the explicit transcription benchmark is running.
/// Absence means that transcription performs no benchmark observation or fault control.
public struct TranscriptionBenchmarkInstrumentation: Sendable {
    public let observer: any TranscriptionBenchmarkObserving
    public let transportControl: TranscriptionBenchmarkTransportControl?

    public init(
        observer: any TranscriptionBenchmarkObserving,
        transportControl: TranscriptionBenchmarkTransportControl? = nil
    ) {
        self.observer = observer
        self.transportControl = transportControl
    }
}
