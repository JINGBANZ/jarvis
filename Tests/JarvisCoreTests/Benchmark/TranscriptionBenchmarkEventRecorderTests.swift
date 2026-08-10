import Foundation
import Testing
@testable import JarvisCore

@Suite("Transcription benchmark event recorder")
struct TranscriptionBenchmarkEventRecorderTests {
    @Test("a standard final stream settles only after the latest final stays quiet")
    func finalStreamSettlementIncludesLateFragments() async throws {
        let recorder = TranscriptionBenchmarkEventRecorder()
        let waiter = Task {
            try await recorder.waitForFinalStreamToSettle(
                minimumCount: 1,
                quietPeriod: 0.12,
                timeout: 1)
            return recorder.snapshot().events.filter { $0.kind == .finalized }.count
        }

        recorder.record(event(text: "first", observedAt: 1))
        try await Task.sleep(for: .milliseconds(60))
        recorder.record(event(text: "second", observedAt: 2))

        #expect(try await waiter.value == 2)
    }

    @Test("reconnect settlement includes finals after both expected phrases")
    func reconnectSettlementIncludesLateFinals() async throws {
        let phraseIDs = ["english-technical", "mandarin-technical"]
        let phrases = phraseIDs.map { id in
            TranscriptionBenchmark.phrases.first { $0.id == id }!
        }
        let recorder = TranscriptionBenchmarkEventRecorder()
        let waiter = Task {
            try await recorder.waitForRecognizedReconnectFinalStreamToSettle(
                phraseIDs,
                inGeneration: 1,
                quietPeriod: 0.12,
                timeout: 1)
            return recorder.snapshot().events.filter { $0.kind == .finalized }.count
        }

        recorder.record(event(text: phrases[0].text, observedAt: 1))
        recorder.record(event(text: phrases[1].text, observedAt: 2))
        try await Task.sleep(for: .milliseconds(60))
        recorder.record(event(text: "Unrelated late final", observedAt: 3))

        #expect(try await waiter.value == 3)
    }

    @Test("snapshot returns all content-free benchmark observations")
    func snapshot() {
        let recorder = TranscriptionBenchmarkEventRecorder()
        let diagnostic = event(text: "complete", observedAt: 1)
        recorder.record(diagnostic)
        recorder.record(.reconnecting(attempt: 1))
        recorder.recordCapture(sequence: 7, samples: 2_400)
        recorder.record(.connectionLost)

        let snapshot = recorder.snapshot()
        #expect(snapshot.events == [diagnostic])
        #expect(snapshot.states == [.reconnecting(attempt: 1)])
        #expect(snapshot.captureObservations == [
            .init(sequenceNumber: 7, sampleCount: 2_400),
        ])
        #expect(snapshot.terminalFailure == .connectionLost)
    }

    private func event(text: String, observedAt: TimeInterval) -> TranscriptionDiagnosticEvent {
        .init(
            kind: .finalized,
            provider: TranscriptionProvider.openAI.rawValue,
            model: OpenAITranscriptionModel.gpt4oTranscribe.rawValue,
            speaker: Speaker.them.rawValue,
            generation: 1,
            text: text,
            observedAt: observedAt)
    }
}
