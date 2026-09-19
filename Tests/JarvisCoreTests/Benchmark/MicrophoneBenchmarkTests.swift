import Foundation
import Testing
@testable import JarvisCore

@Suite("Microphone benchmark privacy and scoring")
struct MicrophoneBenchmarkTests {
    @Test func reportScoresInMemoryWithoutSerializingSpeechOrErrors() throws {
        let arm = MicrophoneBenchmark.arms(for: MicrophoneBenchmark.phrases[0])[0]
        let event = TranscriptionBenchmarkEvent(
            kind: .finalized, provider: "openai", speaker: "me", generation: 0,
            itemID: "private-item", text: "Evict expired events from the deck. PRIVATE-SPEECH", observedAt: 12)
        let result = MicrophoneBenchmark.score(
            arm: arm, repetition: 1, events: [.init(kind: .serverEndpoint, provider: "openai", speaker: "me",
                           generation: 0, observedAt: 10), event],
            capture: [.init(sequenceNumber: 1, sampleCount: 240)],
            states: [], droppedChunks: 0, failed: false)
        #expect(result.expectedTermCount == 2)
        #expect(result.recognizedTermCount == 1)
        #expect(result.characterErrorRate! > 0)
        #expect(result.endpointToFinalSeconds == 2)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!json.contains("PRIVATE"))
        #expect(!json.contains("private-item"))
        #expect(!json.contains("finalTexts"))
        #expect(!json.contains("text"))
    }

    @Test func serverEndpointProducesLatencyWithoutClientCommit() {
        let arm = MicrophoneBenchmark.arms(for: MicrophoneBenchmark.phrases[0])[0]
        let result = MicrophoneBenchmark.score(
            arm: arm, repetition: 1,
            events: [
                .init(kind: .serverEndpoint, provider: "openai", speaker: "me", generation: 0, observedAt: 10),
                .init(kind: .finalized, provider: "openai", speaker: "me", generation: 0,
                      text: "Evict expired events from the deque.", observedAt: 12)
            ], capture: [.init(sequenceNumber: 1, sampleCount: 240)], states: [],
            droppedChunks: 0, failed: false)
        #expect(result.endpointToFinalSeconds == 2)
    }

    @Test func droppedAudioAndMissingFinalCannotPass() {
        let arm = MicrophoneBenchmark.arms(for: MicrophoneBenchmark.phrases[0])[0]
        let result = MicrophoneBenchmark.score(
            arm: arm, repetition: 1, events: [],
            capture: [.init(sequenceNumber: 1, sampleCount: 240)],
            states: [], droppedChunks: 1, failed: false)
        #expect(!result.usable)
        #expect(result.missingFinal)
        #expect(result.characterErrorRate == nil)
        #expect(result.endpointToFinalSeconds == nil)
    }

    @Test func unrelatedTermInsertionIsCounted() {
        let arm = MicrophoneBenchmark.arms(for: MicrophoneBenchmark.phrases[4])[1]
        let result = MicrophoneBenchmark.score(
            arm: arm, repetition: 1,
            events: [.init(kind: .finalized, provider: "openai", speaker: "me", generation: 0,
                           text: "Please send the deque.", observedAt: 5)],
            capture: [.init(sequenceNumber: 1, sampleCount: 240)],
            states: [], droppedChunks: 0, failed: false)
        #expect(result.unexpectedTechnicalTermCount == 1)
        #expect(result.expectedTermCount == 0)
    }
}
