public struct TranscriptionBenchmarkInstrumentation: Sendable {
    public let observer: any TranscriptionBenchmarkObserving
    public let transcriptionPrompt: String?
    public let transportControl: TranscriptionBenchmarkTransportControl?

    public init(
        observer: any TranscriptionBenchmarkObserving,
        transportControl: TranscriptionBenchmarkTransportControl? = nil,
        transcriptionPrompt: String? = nil
    ) {
        self.observer = observer
        self.transcriptionPrompt = transcriptionPrompt
        self.transportControl = transportControl
    }
}
