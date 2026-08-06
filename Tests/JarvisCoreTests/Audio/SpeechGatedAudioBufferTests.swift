import Foundation
import Testing
@testable import JarvisCore

@Suite struct SpeechGatedAudioBufferTests {
    @Test func longIdleKeepsOnlyConfiguredPreRollAtSpeechOnset() {
        var buffer = SpeechGatedAudioBuffer(maximumPreRollDuration: 0.3)

        for sequence in 1...10 {
            #expect(buffer.append(chunk(UInt64(sequence), duration: 0.1)).isEmpty)
        }

        #expect(buffer.speechStarted().compactMap(\.sequenceNumber) == [8, 9, 10])
        #expect(buffer.append(chunk(11, duration: 0.1)).compactMap(\.sequenceNumber) == [11])
    }

    @Test func activeSpeechAndTrailingSilencePassButNextTurnIdleStaysLocal() {
        var buffer = SpeechGatedAudioBuffer(maximumPreRollDuration: 0.2)

        #expect(buffer.append(chunk(1, duration: 0.1)).isEmpty)
        #expect(buffer.speechStarted().compactMap(\.sequenceNumber) == [1])
        #expect(buffer.append(chunk(2, duration: 0.1)).compactMap(\.sequenceNumber) == [2])
        #expect(buffer.append(chunk(3, duration: 0.1)).compactMap(\.sequenceNumber) == [3])
        buffer.speechEnded()

        for sequence in 4...8 {
            #expect(buffer.append(chunk(UInt64(sequence), duration: 0.1)).isEmpty)
        }
        #expect(buffer.speechStarted().compactMap(\.sequenceNumber) == [7, 8])
    }

    @Test func reconnectKeepsPendingTurnAudioSeparateFromBoundedNextTurnPreRoll() throws {
        var gate = SpeechGatedAudioBuffer(maximumPreRollDuration: 0.2)
        let reconnectBuffer = PCMBuffer(maxBytes: 1_000)
        var coordinator = RealtimeJarvisManagedTurnCoordinator()

        _ = gate.append(chunk(1, duration: 0.1))
        _ = gate.append(chunk(2, duration: 0.1))
        for ready in gate.speechStarted() {
            reconnectBuffer.append(
                ready.data, sequenceNumber: ready.sequenceNumber,
                capturedAt: ready.capturedAt, duration: ready.duration)
        }
        for ready in gate.append(chunk(3, duration: 0.1)) {
            reconnectBuffer.append(
                ready.data, sequenceNumber: ready.sequenceNumber,
                capturedAt: ready.capturedAt, duration: ready.duration)
        }
        gate.speechEnded()
        coordinator.recordTurn(startedAt: 0.1, committedThroughAt: 0.3, throughSequenceNumber: 3)

        for sequence in 4...10 {
            #expect(gate.append(chunk(UInt64(sequence), duration: 0.1)).isEmpty)
        }

        let firstClaim = try #require(reconnectBuffer.claimNext())
        #expect(reconnectBuffer.completeSend(firstClaim) != nil)
        coordinator.recordAudioSent(sequenceNumber: 1)

        let replay = reconnectBuffer.prepareForReconnect()
        #expect(replay.oldestSequenceNumber == 1)
        #expect(coordinator.prepareForReconnect(
            oldestAvailableSequenceNumber: replay.oldestSequenceNumber).isEmpty)
        #expect(coordinator.unresolvedTurnCount == 1)
        #expect(reconnectBuffer.drainChunks().compactMap(\.sequenceNumber) == [1, 2, 3])
        #expect(gate.speechStarted().compactMap(\.sequenceNumber) == [9, 10])
    }

    private func chunk(_ sequence: UInt64, duration: TimeInterval) -> PCMBuffer.Chunk {
        PCMBuffer.Chunk(
            data: Data([UInt8(sequence)]),
            sequenceNumber: sequence,
            capturedAt: TimeInterval(sequence) * duration,
            duration: duration)
    }
}
