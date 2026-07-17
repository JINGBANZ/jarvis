import Foundation
import Testing
@testable import JarvisCore

@Suite struct AudioContinuityWitnessTests {
    @Test func periodicSnapshotContainsOnlyContentFreeContinuityMetadata() throws {
        let witness = makeWitness(snapshotInterval: 1)
        #expect(witness.recordCapture(sequence: 10, sampleCount: 480, at: 0).snapshot == nil)
        _ = witness.recordDelivery(sequence: 10, pcm16: pcm(amplitude: 1_000), at: 0.05)
        _ = witness.recordSendAttempt(sequence: 10, socketGeneration: 2, at: 0.06)
        _ = witness.recordSendSuccess(sequence: 10, socketGeneration: 2, at: 0.07)
        _ = witness.recordServerSpeech(.speechStarted, audioTimeMilliseconds: 40,
                                       socketGeneration: 2, sessionAudioTime: 0.04,
                                       observedAt: 0.08)

        let snapshot = try #require(witness.poll(at: 1).snapshot)
        #expect(snapshot.capturedChunks == 1)
        #expect(snapshot.capturedSamples == 480)
        #expect(snapshot.deliveredChunks == 1)
        #expect(snapshot.deliveredSamples == 480)
        #expect(snapshot.pendingCapturedChunks == 0)
        #expect(snapshot.localActivityDetected)
        #expect(snapshot.latestSocketGeneration == 2)
        let socket = try #require(snapshot.socketGenerations.first)
        #expect(socket.sendAttempts == 1)
        #expect(socket.sendSuccesses == 1)
        #expect(socket.sendFailures == 0)
        #expect(socket.lastSendSequence == 10)
        #expect(socket.serverSpeechSignals == 1)
        #expect(socket.lastServerSignal == .speechStarted)
        #expect(socket.lastServerAudioTimeMilliseconds == 40)
    }

    @Test func captureStallEmitsOncePerIncidentAndResetsAfterCapture() {
        let witness = makeWitness(captureStallThreshold: 2)
        let first = witness.poll(at: 2.5)
        #expect(first.anomalies == [.captureStalled(lastCaptureAt: nil, duration: 2.5)])
        #expect(witness.poll(at: 3).anomalies.isEmpty)

        #expect(witness.recordCapture(sequence: 0, sampleCount: 480, at: 3).anomalies.isEmpty)
        let second = witness.poll(at: 5.5)
        #expect(second.anomalies == [.captureStalled(lastCaptureAt: 3, duration: 2.5)])
        #expect(witness.poll(at: 6).anomalies.isEmpty)
    }

    @Test func recoveryCaptureReportsAnUnpolledStallExactlyOnce() {
        let witness = makeWitness(captureStallThreshold: 1)
        let recovered = witness.recordCapture(sequence: 0, sampleCount: 10, at: 2)
        #expect(recovered.anomalies == [.captureStalled(lastCaptureAt: nil, duration: 2)])
        #expect(witness.poll(at: 2.5).anomalies.isEmpty)
    }

    @Test func pendingCaptureReportsDeliveryLagBeforeDeliveryRecovers() {
        let witness = makeWitness(deliveryLagThreshold: 0.25)
        _ = witness.recordCapture(sequence: 12, sampleCount: 480, at: 0)

        let blocked = witness.poll(at: 0.5)
        #expect(blocked.anomalies == [.captureToDeliveryLag(sequence: 12, lag: 0.5)])
        #expect(witness.poll(at: 0.75).anomalies.isEmpty)
        #expect(witness.recordDelivery(sequence: 12, pcm16: pcm(amplitude: 0), at: 1)
            .anomalies.isEmpty)
    }

    @Test func deliveryLagIsLatchedUntilAHealthyDeliveryAndSequenceGapsAreTyped() {
        let witness = makeWitness(deliveryLagThreshold: 0.2)
        _ = witness.recordCapture(sequence: 1, sampleCount: 480, at: 0)
        let first = witness.recordDelivery(sequence: 1, pcm16: pcm(amplitude: 0), at: 0.5)
        #expect(first.anomalies.contains(.captureToDeliveryLag(sequence: 1, lag: 0.5)))

        _ = witness.recordCapture(sequence: 2, sampleCount: 480, at: 0.6)
        let stillLagging = witness.recordDelivery(sequence: 2, pcm16: pcm(amplitude: 0), at: 1.1)
        #expect(!stillLagging.anomalies.contains(where: { if case .captureToDeliveryLag = $0 { true } else { false } }))

        let captureGap = witness.recordCapture(sequence: 4, sampleCount: 480, at: 1.25)
        #expect(captureGap.anomalies.contains(.sequenceGap(stage: .capture,
                                                           expected: 3, observed: 4)))
        let healthy = witness.recordDelivery(sequence: 4, pcm16: pcm(amplitude: 0), at: 1.375)
        #expect(healthy.anomalies.contains(.sequenceGap(stage: .delivery, expected: 3, observed: 4)))
        _ = witness.recordCapture(sequence: 5, sampleCount: 480, at: 1.5)
        let lagAgain = witness.recordDelivery(sequence: 5, pcm16: pcm(amplitude: 0), at: 2)
        #expect(lagAgain.anomalies.contains(.captureToDeliveryLag(sequence: 5, lag: 0.5)))

        let actualCaptureGap = witness.recordCapture(sequence: 7, sampleCount: 480, at: 2.1)
        #expect(actualCaptureGap.anomalies.contains(.sequenceGap(stage: .capture, expected: 6, observed: 7)))
    }

    @Test func missingCaptureAndSampleMismatchAreVisibleWithoutAudioContent() {
        let witness = makeWitness()
        let noCapture = witness.recordDelivery(sequence: 3, pcm16: pcm(amplitude: 0, count: 4), at: 0)
        #expect(noCapture.anomalies == [.deliveryWithoutCapture(sequence: 3)])

        _ = witness.recordCapture(sequence: 4, sampleCount: 8, at: 0.1)
        let mismatch = witness.recordDelivery(sequence: 4, pcm16: pcm(amplitude: 0, count: 4), at: 0.1)
        #expect(mismatch.anomalies.contains(.deliverySampleCountMismatch(sequence: 4,
                                                                         captured: 8, delivered: 4)))
    }

    @Test func sustainedLocalActivityWithoutServerSpeechEmitsOncePerActivityEpisode() {
        let witness = makeWitness(sustainedActivityDuration: 0.5, serverSpeechGrace: 0.5)
        _ = witness.recordCapture(sequence: 0, sampleCount: 480, at: 0)
        _ = witness.recordDelivery(sequence: 0, pcm16: pcm(amplitude: 1_000), at: 0.01)
        _ = witness.recordCapture(sequence: 1, sampleCount: 480, at: 0.4)
        _ = witness.recordDelivery(sequence: 1, pcm16: pcm(amplitude: 1_000), at: 0.41)
        _ = witness.recordCapture(sequence: 2, sampleCount: 480, at: 0.6)
        _ = witness.recordDelivery(sequence: 2, pcm16: pcm(amplitude: 1_000), at: 0.61)

        let unmatched = witness.poll(at: 1.11)
        #expect(unmatched.anomalies == [.localActivityUnmatched(activeSince: 0, duration: 1.11)])
        #expect(witness.poll(at: 2).anomalies.isEmpty)

        _ = witness.recordCapture(sequence: 3, sampleCount: 480, at: 2.1)
        _ = witness.recordDelivery(sequence: 3, pcm16: pcm(amplitude: 0), at: 2.11)
        _ = witness.recordCapture(sequence: 4, sampleCount: 480, at: 3)
        _ = witness.recordDelivery(sequence: 4, pcm16: pcm(amplitude: 1_000), at: 3.01)
        _ = witness.recordCapture(sequence: 5, sampleCount: 480, at: 3.6)
        _ = witness.recordDelivery(sequence: 5, pcm16: pcm(amplitude: 1_000), at: 3.61)
        _ = witness.recordServerSpeech(.speechStarted, audioTimeMilliseconds: 3_000,
                                       socketGeneration: 1, sessionAudioTime: 3,
                                       observedAt: 3.7)
        #expect(!witness.poll(at: 5).anomalies.contains(where: {
            if case .localActivityUnmatched = $0 { true } else { false }
        }))
    }

    @Test func oneLoudChunkIsNotSustainedActivity() {
        let witness = makeWitness(sustainedActivityDuration: 0.5, serverSpeechGrace: 0.5)
        _ = witness.recordCapture(sequence: 0, sampleCount: 480, at: 0)
        _ = witness.recordDelivery(sequence: 0, pcm16: pcm(amplitude: 2_000), at: 0.01)

        #expect(!witness.poll(at: 2).anomalies.contains(where: {
            if case .localActivityUnmatched = $0 { true } else { false }
        }))
    }

    @Test func lateServerSpeechExplicitlyResolvesAnAlreadyReportedActivityWarning() {
        let witness = makeWitness(sustainedActivityDuration: 0.5, serverSpeechGrace: 0.5)
        for (sequence, time) in [(0, 0.0), (1, 0.3), (2, 0.6)] {
            _ = witness.recordCapture(sequence: UInt64(sequence), sampleCount: 480, at: time)
            _ = witness.recordDelivery(sequence: UInt64(sequence),
                                       pcm16: pcm(amplitude: 1_000), at: time)
        }
        #expect(witness.poll(at: 1.11).anomalies.contains(
            .localActivityUnmatched(activeSince: 0, duration: 1.11)))
        _ = witness.recordSendAttempt(sequence: 2, socketGeneration: 2, at: 1.2)
        #expect(witness.poll(at: 1.4).anomalies.isEmpty)

        let resolved = witness.recordServerSpeech(
            .speechStarted, audioTimeMilliseconds: 0,
            socketGeneration: 2, sessionAudioTime: 0.3, observedAt: 1.5)
        #expect(resolved.anomalies == [.serverSpeechObservedAfterUnmatchedActivity(
            activeSince: 0, serverObservedAt: 1.5)])
        #expect(witness.poll(at: 3).anomalies.isEmpty)
    }

    @Test func delayedTerminalEventCannotMatchANewerLocalActivityEpisode() {
        let witness = makeWitness(sustainedActivityDuration: 0.5, serverSpeechGrace: 0.5)
        for (sequence, time) in [(0, 0.0), (1, 0.3), (2, 0.6)] {
            _ = witness.recordCapture(sequence: UInt64(sequence), sampleCount: 480, at: time)
            _ = witness.recordDelivery(sequence: UInt64(sequence),
                                       pcm16: pcm(amplitude: 1_000), at: time)
        }
        #expect(witness.poll(at: 1.11).anomalies.contains(
            .localActivityUnmatched(activeSince: 0, duration: 1.11)))

        for (sequence, time) in [(3, 3.0), (4, 3.3), (5, 3.6)] {
            _ = witness.recordCapture(sequence: UInt64(sequence), sampleCount: 480, at: time)
            _ = witness.recordDelivery(sequence: UInt64(sequence),
                                       pcm16: pcm(amplitude: 1_000), at: time)
        }
        _ = witness.recordServerSpeech(
            .transcriptionCompleted, audioTimeMilliseconds: nil,
            socketGeneration: 1, observedAt: 3.7)

        #expect(witness.poll(at: 4.11).anomalies.contains(where: {
            guard case .localActivityUnmatched(let activeSince, let duration) = $0 else {
                return false
            }
            return abs(activeSince - 3) < 0.001 && abs(duration - 1.11) < 0.001
        }))
    }

    @Test func serverSpeechStartMatchesOnlyTheOverlappingLocalEpisode() {
        let witness = makeWitness(sustainedActivityDuration: 0.5, serverSpeechGrace: 0.5)
        for (sequence, time) in [(0, 3.0), (1, 3.3), (2, 3.6)] {
            _ = witness.recordCapture(sequence: UInt64(sequence), sampleCount: 480, at: time)
            _ = witness.recordDelivery(sequence: UInt64(sequence),
                                       pcm16: pcm(amplitude: 1_000), at: time)
        }
        _ = witness.recordServerSpeech(
            .speechStarted, audioTimeMilliseconds: 100,
            socketGeneration: 1, sessionAudioTime: 0.1, observedAt: 3.7)
        #expect(witness.poll(at: 4.11).anomalies.contains(where: {
            guard case .localActivityUnmatched(let activeSince, let duration) = $0 else {
                return false
            }
            return abs(activeSince - 3) < 0.001 && abs(duration - 1.11) < 0.001
        }))

        let matching = makeWitness(sustainedActivityDuration: 0.5, serverSpeechGrace: 0.5)
        for (sequence, time) in [(0, 3.0), (1, 3.3), (2, 3.6)] {
            _ = matching.recordCapture(sequence: UInt64(sequence), sampleCount: 480, at: time)
            _ = matching.recordDelivery(sequence: UInt64(sequence),
                                        pcm16: pcm(amplitude: 1_000), at: time)
        }
        _ = matching.recordServerSpeech(
            .speechStarted, audioTimeMilliseconds: 3_200,
            socketGeneration: 1, sessionAudioTime: 3.2, observedAt: 3.7)
        #expect(!matching.poll(at: 4.11).anomalies.contains(where: {
            if case .localActivityUnmatched = $0 { true } else { false }
        }))
    }

    @Test func speechEndingBeforeServerGraceStillProducesAnUnmatchedActivityAnomaly() {
        let witness = makeWitness(sustainedActivityDuration: 0.5, serverSpeechGrace: 0.5)
        for (sequence, time) in [(0, 0.0), (1, 0.25), (2, 0.55)] {
            _ = witness.recordCapture(sequence: UInt64(sequence), sampleCount: 480, at: time)
            _ = witness.recordDelivery(sequence: UInt64(sequence),
                                       pcm16: pcm(amplitude: 1_000), at: time)
        }
        _ = witness.recordCapture(sequence: 3, sampleCount: 480, at: 0.8)
        _ = witness.recordDelivery(sequence: 3, pcm16: pcm(amplitude: 0), at: 0.8)

        #expect(!witness.poll(at: 1).anomalies.contains(where: {
            if case .localActivityUnmatched = $0 { true } else { false }
        }))
        #expect(witness.poll(at: 1.06).anomalies.contains(
            .localActivityUnmatched(activeSince: 0, duration: 1.06)))
    }

    @Test func sendMetadataIsSeparatedAndSortedBySocketGeneration() throws {
        let witness = makeWitness()
        _ = witness.recordSendAttempt(sequence: 8, socketGeneration: 3, at: 1)
        _ = witness.recordSendFailure(sequence: 8, socketGeneration: 3, at: 1.1)
        _ = witness.recordSendAttempt(sequence: 9, socketGeneration: 4, at: 2)
        _ = witness.recordSendSuccess(sequence: 9, socketGeneration: 4, at: 2.1)

        let snapshot = try #require(witness.poll(at: 2.2, forceSnapshot: true).snapshot)
        #expect(snapshot.socketGenerations.map(\.generation) == [3, 4])
        #expect(snapshot.socketGenerations[0].sendFailures == 1)
        #expect(snapshot.socketGenerations[1].sendSuccesses == 1)
        #expect(snapshot.latestSocketGeneration == 4)
    }

    @Test func reconnectBufferOverflowRecordsOnlyContentFreeSequenceEvidence() {
        let witness = makeWitness()

        let output = witness.recordReconnectBufferOverflow(
            evictedSequences: [101, 102, 103], at: 4)

        #expect(output.anomalies == [.reconnectBufferOverflow(
            evictedChunks: 3, firstSequence: 101, lastSequence: 103)])
    }

    private func makeWitness(snapshotInterval: TimeInterval = 100,
                             captureStallThreshold: TimeInterval = 100,
                             deliveryLagThreshold: TimeInterval = 100,
                             sustainedActivityDuration: TimeInterval = 100,
                             serverSpeechGrace: TimeInterval = 100) -> AudioContinuityWitness {
        AudioContinuityWitness(configuration: .init(
            snapshotInterval: snapshotInterval,
            captureStallThreshold: captureStallThreshold,
            deliveryLagThreshold: deliveryLagThreshold,
            sustainedActivityDuration: sustainedActivityDuration,
            serverSpeechGrace: serverSpeechGrace,
            activity: .init(initialNoiseFloorRMS: 80, minimumNoiseFloorRMS: 20,
                            minimumActiveRMS: 200, minimumActivePeak: 500,
                            activationMultiplier: 3, releaseMultiplier: 1.5,
                            noiseAdaptationRate: 0.05)
        ), startedAt: 0)
    }

    private func pcm(amplitude: Int16, count: Int = 480) -> Data {
        let samples = (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
        return samples.withUnsafeBytes { Data($0) }
    }
}
