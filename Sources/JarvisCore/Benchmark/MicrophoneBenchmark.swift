import Foundation

public enum MicrophoneBenchmark {
    public static let phrases: [TranscriptionBenchmark.Phrase] = [
        ("evict", "Evict expired events from the deque."),
        ("window", "Maintain the min and max for each window."),
        ("timestamp", "The timestamp equals the cutoff."),
        ("complexity", "Each event costs amortized O of one, not O of N."),
        ("ordinary", "Please move our meeting to Friday afternoon and send me the new address."),
        ("pause", "The deque. Evict the oldest.")
    ].map { .init(id: $0.0, language: .english, text: $0.1, voice: "") }

    public static func arms(for phrase: TranscriptionBenchmark.Phrase) -> [TranscriptionBenchmark.Arm] {
        [false, true].map { hinted in
            .init(id: hinted ? "context" : "baseline", provider: .openAI,
                  model: .gpt4oTranscribe, languageProfile: .english, localeIdentifier: nil,
                  phrase: phrase,
                  transcriptionPrompt: hinted ? TranscriptionBenchmark.technicalContextPrompt : nil)
        }
    }

    public struct Result: Codable, Sendable {
        public let phraseID: String
        public let armID: String
        public let repetition: Int
        public let characterErrorRate: Double?
        public let expectedTermCount: Int
        public let recognizedTermCount: Int
        public let unexpectedTechnicalTermCount: Int
        public let endpointToFinalSeconds: Double?
        public let missingFinal: Bool
        public let capturedSamples: Int
        public let droppedChunks: Int
        public let usable: Bool
    }

    public struct Summary: Codable, Sendable {
        public let mode: String
        public let results: [Result]
        public init(results: [Result]) { mode = "microphone"; self.results = results }
    }

    // Only measurements cross the serialization boundary: provider text and identifiers stay in memory.
    public static func score(
        arm: TranscriptionBenchmark.Arm, repetition: Int,
        events: [TranscriptionBenchmarkEvent], capture: [TranscriptionBenchmark.CaptureObservation],
        states: [TranscriptionConnectionState], droppedChunks: Int, failed: Bool
    ) -> Result {
        let scored = TranscriptionBenchmark.evaluate(.init(
            arm: arm, repetition: repetition, fixtureSHA256: "",
            connectStartedAt: 0, speechEndedAt: 0,
            events: events, captureObservations: capture, connectionStates: states))
        let technicalTerms: Set<String> = ["evict", "deque", "min", "max", "timestamp", "cutoff", "amortized"]
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let expected = words(arm.phrase.text).intersection(technicalTerms)
        let actual = words(scored.finalTexts.joined(separator: " ")).intersection(technicalTerms)
        let finalAt = events.filter { $0.kind == .finalized && !$0.transcriptUnavailable }
            .map(\.observedAt).max()
        let endpointAt = events.filter { $0.kind == .serverEndpoint }.map(\.observedAt).max()
        let latency = endpointAt.flatMap { endpoint in
            finalAt.map { max(0, $0 - endpoint) }
        }
        return .init(
            phraseID: arm.phrase.id, armID: arm.id, repetition: repetition,
            characterErrorRate: scored.normalizedCharacterErrorRate,
            expectedTermCount: expected.count, recognizedTermCount: expected.intersection(actual).count,
            unexpectedTechnicalTermCount: actual.subtracting(expected).count,
            endpointToFinalSeconds: latency, missingFinal: scored.missing,
            capturedSamples: scored.capturedSampleCount, droppedChunks: droppedChunks,
            usable: !failed && scored.failure == nil && scored.continuityPassed
                && droppedChunks == 0 && !scored.missing && scored.unavailableCount == 0)
    }
}
