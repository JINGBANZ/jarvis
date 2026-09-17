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
