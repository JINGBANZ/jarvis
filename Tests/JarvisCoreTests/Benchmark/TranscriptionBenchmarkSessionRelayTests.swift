import Foundation
import Testing
@testable import JarvisCore

private final class BenchmarkSessionSpy: TranscriptionSession, @unchecked Sendable {
    struct Delivery: Equatable, Sendable {
        let sequence: UInt64
        let samples: Int
        let capturedAt: TimeInterval
        let data: Data
        let speechEvents: [LocalSpeechEvent]
    }

    var onTurnEnd: (@Sendable () -> Void)?
    var onSilence: (@Sendable (TimeInterval) -> Void)?
    var onSpeechActivityChanged: (@Sendable (Bool) -> Void)?
    var onConnectionStateChange: (@Sendable (TranscriptionConnectionState) -> Void)?
    var onTerminalFailure: (@Sendable (TranscriptionFailureReason) -> Void)?
    var onCaptureContinuity: (@Sendable (CaptureReadinessMonitor.Signal) -> Void)?
    private let lock = NSLock()
    private var captured: [(UInt64, Int, TimeInterval)] = []
    private var sent: [(Data, UInt64, TimeInterval)] = []
    private var speech: [(LocalSpeechEvent, UInt64)] = []

    func connect() {}
    func stop() {}

    func recordCapturedAudio(
        sequenceNumber: UInt64,
        sampleCount: Int,
        capturedAt: TimeInterval
    ) {
        lock.lock(); captured.append((sequenceNumber, sampleCount, capturedAt)); lock.unlock()
    }

    func sendAudio(_ pcm: Data, sequenceNumber: UInt64, capturedAt: TimeInterval) {
        lock.lock(); sent.append((pcm, sequenceNumber, capturedAt)); lock.unlock()
    }

    func recordLocalSpeechEvent(
        _ event: LocalSpeechEvent,
        throughSequenceNumber: UInt64
    ) {
        lock.lock(); speech.append((event, throughSequenceNumber)); lock.unlock()
    }

    func snapshot() -> Delivery? {
        lock.lock(); defer { lock.unlock() }
        guard let capture = captured.first, let send = sent.first else { return nil }
        return Delivery(
            sequence: capture.0,
            samples: capture.1,
            capturedAt: capture.2,
            data: send.0,
            speechEvents: speech.map(\.0))
    }
}

private final class BenchmarkCaptureSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [(UInt64, Int)] = []

    func record(sequence: UInt64, samples: Int) {
        lock.lock(); observations.append((sequence, samples)); lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return observations.count
    }
}

@Suite("Transcription benchmark session relay")
struct TranscriptionBenchmarkSessionRelayTests {
    @Test("one delivery uses one installed session snapshot for every audio edge")
    func deliversOneAtomicSnapshot() throws {
        let relay = TranscriptionBenchmarkSessionRelay()
        let first = BenchmarkSessionSpy()
        let second = BenchmarkSessionSpy()
        let firstCapture = BenchmarkCaptureSpy()
        let secondCapture = BenchmarkCaptureSpy()
        let pcm = Data([1, 2, 3, 4])
        let speechEvents: [LocalSpeechEvent] = [
            .started(at: 1),
            .ended(startedAt: 1, commitAt: 1.5),
        ]

        relay.install(first) { firstCapture.record(sequence: $0, samples: $1) }
        relay.deliver(
            pcm,
            sequence: 7,
            samples: 2,
            capturedAt: 1.5,
            speechEvents: speechEvents)
        relay.install(second) { secondCapture.record(sequence: $0, samples: $1) }
        relay.deliver(
            pcm,
            sequence: 8,
            samples: 2,
            capturedAt: 2,
            speechEvents: [])

        let firstDelivery = try #require(first.snapshot())
        let secondDelivery = try #require(second.snapshot())
        #expect(firstDelivery == .init(
            sequence: 7,
            samples: 2,
            capturedAt: 1.5,
            data: pcm,
            speechEvents: speechEvents))
        #expect(secondDelivery.sequence == 8)
        #expect(firstCapture.count == 1)
        #expect(secondCapture.count == 1)
    }

    @Test("an enqueued chunk stays with the target installed when it was queued")
    func queuedChunkDoesNotCrossTheInstallBoundary() throws {
        let relay = TranscriptionBenchmarkSessionRelay()
        let first = BenchmarkSessionSpy()
        let second = BenchmarkSessionSpy()
        let firstCapture = BenchmarkCaptureSpy()
        let secondCapture = BenchmarkCaptureSpy()
        let pcm = Data([1, 2, 3, 4])

        relay.install(first) { firstCapture.record(sequence: $0, samples: $1) }
        relay.enqueue(
            pcm,
            sequence: 7,
            samples: 2,
            capturedAt: 1.5,
            speechEvents: [])
        relay.install(second) { secondCapture.record(sequence: $0, samples: $1) }

        let delivery = try #require(first.snapshot())
        #expect(delivery.sequence == 7)
        #expect(firstCapture.count == 1)
        #expect(second.snapshot() == nil)
        #expect(secondCapture.count == 0)
    }
}
