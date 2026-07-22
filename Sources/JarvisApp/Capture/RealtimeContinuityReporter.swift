import Foundation
import JarvisCore

/// Owns privacy-preserving continuity observation, periodic snapshots, overflow aggregation, and
/// diagnostic logging. It never appends to the transcript or exposes audio content to the coach.
///
/// `@unchecked Sendable`: `lock` guards lifecycle and overflow state; `AudioContinuityWitness`
/// independently guards its state, and timer creation/invalidation is dispatched to the main queue.
final class RealtimeContinuityReporter: @unchecked Sendable {
    private let speaker: Speaker
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let witness: AudioContinuityWitness
    private let lock = NSLock()
    private var timer: Timer?
    private var stopped = true
    private var overflowAccumulator = ReconnectBufferOverflowAccumulator()

    init(speaker: Speaker, clock: Clock, sessionStart: TimeInterval) {
        self.speaker = speaker
        self.clock = clock
        self.sessionStart = sessionStart
        witness = AudioContinuityWitness(startedAt: 0)
    }

    func start() {
        lock.lock()
        stopped = false
        overflowAccumulator.reset()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let shouldStart = !self.stopped; self.lock.unlock()
            guard shouldStart else { return }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
                [weak self] _ in
                guard let self else { return }
                self.consume(self.witness.poll(at: self.now))
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let timer = self.timer
        self.timer = nil
        let overflow = overflowAccumulator.flush(at: now)
        lock.unlock()
        DispatchQueue.main.async { timer?.invalidate() }
        if let overflow {
            handle(witness.recordReconnectBufferOverflow(evictedSequences: overflow, at: now))
        }
        handle(witness.poll(at: now, forceSnapshot: true))
    }

    func recordCapture(sequence: UInt64, sampleCount: Int, at timestamp: TimeInterval) {
        consume(witness.recordCapture(sequence: sequence, sampleCount: sampleCount, at: timestamp))
    }

    func recordDelivery(sequence: UInt64, pcm16: Data, at timestamp: TimeInterval) {
        consume(witness.recordDelivery(sequence: sequence, pcm16: pcm16, at: timestamp))
    }

    func recordSendAttempt(sequence: UInt64, socketGeneration: Int) {
        consume(witness.recordSendAttempt(sequence: sequence, socketGeneration: socketGeneration,
                                          at: now))
    }

    func recordSendSuccess(sequence: UInt64, socketGeneration: Int) {
        consume(witness.recordSendSuccess(sequence: sequence, socketGeneration: socketGeneration,
                                          at: now))
    }

    func recordSendFailure(sequence: UInt64, socketGeneration: Int) {
        consume(witness.recordSendFailure(sequence: sequence, socketGeneration: socketGeneration,
                                          at: now))
    }

    func recordServerSpeech(
        _ signal: AudioContinuityWitness.ServerSpeechSignal,
        audioTimeMilliseconds: Int?, itemID: String? = nil,
        sessionAudioTime: TimeInterval? = nil, socketGeneration: Int
    ) {
        consume(witness.recordServerSpeech(
            signal, audioTimeMilliseconds: audioTimeMilliseconds,
            socketGeneration: socketGeneration, itemID: itemID,
            sessionAudioTime: sessionAudioTime, observedAt: now))
    }

    func recordBufferEviction(_ chunks: [PCMBuffer.Chunk]) {
        guard !chunks.isEmpty else { return }
        let timestamp = now
        lock.lock()
        let sequences = overflowAccumulator.record(chunks.compactMap(\.sequenceNumber), at: timestamp)
        lock.unlock()
        guard let sequences else { return }
        consume(witness.recordReconnectBufferOverflow(evictedSequences: sequences, at: timestamp))
    }

    private var now: TimeInterval { clock.now() - sessionStart }

    /// Calls originate on audio, URLSession, and main queues. Preserve the observation at its source
    /// boundary, but keep logging off the realtime audio callback.
    private func consume(_ output: AudioContinuityWitness.Output) {
        guard output.snapshot != nil || !output.anomalies.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
            guard !stopped else { return }
            self.handle(output)
        }
    }

    private func handle(_ output: AudioContinuityWitness.Output) {
        if let snapshot = output.snapshot {
            let sockets = snapshot.socketGenerations.map { socket in
                let lastSequence = socket.lastSendSequence.map(String.init) ?? "none"
                return "g\(socket.generation):attempt=\(socket.sendAttempts),ok=\(socket.sendSuccesses),"
                    + "fail=\(socket.sendFailures),server=\(socket.serverSpeechSignals),"
                    + "last_seq=\(lastSequence)"
            }.joined(separator: ";")
            jlog("Jarvis audio witness [\(speaker.rawValue)] @\(Self.seconds(snapshot.emittedAt)): "
                 + "capture=\(snapshot.capturedChunks)/\(snapshot.capturedSamples), "
                 + "delivery=\(snapshot.deliveredChunks)/\(snapshot.deliveredSamples), "
                 + "pending=\(snapshot.pendingCapturedChunks), active=\(snapshot.localActivityDetected), "
                 + "sockets=[\(sockets)]")
        }

        for anomaly in output.anomalies {
            switch anomaly {
            case .captureStalled(let lastCaptureAt, let duration):
                let lastCapture = lastCaptureAt.map(Self.seconds) ?? "never"
                jlog("⚠️ audio continuity [\(speaker.rawValue)] capture stalled for "
                     + "\(Self.seconds(duration)) (last=\(lastCapture))")
            case .sequenceGap(let stage, let expected, let observed):
                let boundary = stage == .capture ? "capture" : "delivery"
                jlog("⚠️ audio continuity [\(speaker.rawValue)] \(boundary) sequence gap: "
                     + "expected=\(expected), observed=\(observed)")
            case .deliveryWithoutCapture(let sequence):
                jlog("⚠️ audio continuity [\(speaker.rawValue)] delivery had no capture record: "
                     + "sequence=\(sequence)")
            case .deliverySampleCountMismatch(let sequence, let captured, let delivered):
                jlog("⚠️ audio continuity [\(speaker.rawValue)] sample count changed before delivery: "
                     + "sequence=\(sequence), captured=\(captured), delivered=\(delivered)")
            case .captureToDeliveryLag(let sequence, let lag):
                jlog("⚠️ audio continuity [\(speaker.rawValue)] capture-to-delivery lag: "
                     + "sequence=\(sequence), lag=\(Self.seconds(lag))")
            case .reconnectBufferOverflow(let evictedChunks, let firstSequence, let lastSequence):
                let first = firstSequence.map(String.init) ?? "unknown"
                let last = lastSequence.map(String.init) ?? "unknown"
                jlog("⚠️ audio continuity [\(speaker.rawValue)] reconnect buffer overflow: "
                     + "evicted=\(evictedChunks), sequences=\(first)...\(last)")
            case .localActivityUnmatched(let activeSince, let duration):
                jlog("⚠️ audio continuity [\(speaker.rawValue)] local activity had no server speech "
                     + "event: since=\(Self.seconds(activeSince)), window=\(Self.seconds(duration))")
            case .serverSpeechObservedAfterUnmatchedActivity(let activeSince, let serverObservedAt):
                jlog("ℹ️ audio continuity [\(speaker.rawValue)] late server speech event resolved "
                     + "the prior warning: activity_since=\(Self.seconds(activeSince)), "
                     + "server_at=\(Self.seconds(serverObservedAt))")
            }
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.3fs", value)
    }
}
