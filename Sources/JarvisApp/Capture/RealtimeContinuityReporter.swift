import Foundation
import JarvisCore

/// Owns privacy-preserving continuity observation, periodic snapshots, overflow aggregation, and
/// diagnostic logging. It never appends to the transcript or exposes audio content to the coach.
///
/// `@unchecked Sendable`: `lock` guards lifecycle and overflow state; `AudioContinuityWitness`
/// independently guards its state, and timer creation/invalidation is dispatched to the main queue.
final class RealtimeContinuityReporter: @unchecked Sendable {
    enum Boundary: String {
        case openAIRealtime = "OpenAI Realtime"
        case appleSpeech = "Apple Speech"
    }

    private let speaker: Speaker
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let boundary: Boundary
    private let witness: AudioContinuityWitness
    private let lock = NSLock()
    private var timer: Timer?
    private var stopped = true
    private var evictionAccumulator = ReplayBufferEvictionAccumulator()
    /// Latches so positive sample progress is surfaced only for the first frame and the first frame
    /// after a witness stall. Guarded by `lock`.
    private var emittedFirstFrame = false
    private var reportedStall = false

    /// Promotes actual audio-frame arrival into readiness. Fired off the witness's own evidence (no
    /// second counter): positive sample progress on first capture/resume and `.stalled` on the
    /// witness's capture-stalled anomaly. Consumed by `CaptureReadinessMonitor` in the app.
    var onCaptureContinuity: (@Sendable (CaptureReadinessMonitor.Signal) -> Void)?

    init(
        speaker: Speaker,
        clock: Clock,
        sessionStart: TimeInterval,
        boundary: Boundary = .openAIRealtime
    ) {
        self.speaker = speaker
        self.clock = clock
        self.sessionStart = sessionStart
        self.boundary = boundary
        witness = AudioContinuityWitness(startedAt: 0)
    }

    func start() {
        lock.lock()
        stopped = false
        evictionAccumulator.reset()
        emittedFirstFrame = false
        reportedStall = false
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
        let evictionReport = evictionAccumulator.flush(at: now)
        lock.unlock()
        DispatchQueue.main.async { timer?.invalidate() }
        if let evictionReport {
            handle(evictionReport)
        }
        handle(witness.poll(at: now, forceSnapshot: true))
    }

    func recordCapture(sequence: UInt64, sampleCount: Int, at timestamp: TimeInterval) {
        precondition(sampleCount >= 0)
        let witnessOutput = witness.recordCapture(
            sequence: sequence, sampleCount: sampleCount, at: timestamp)
        lock.lock()
        let hasSampleProgress = sampleCount > 0
        let emitCaptureProgress = hasSampleProgress && (!emittedFirstFrame || reportedStall)
        if hasSampleProgress {
            emittedFirstFrame = true
            reportedStall = false
        }
        lock.unlock()
        // Positive sample progress is health regardless of amplitude; a zero-length callback is not.
        if emitCaptureProgress {
            onCaptureContinuity?(.captured(sampleCount: sampleCount))
        }
        consume(witnessOutput)
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

    func recordBufferEviction(_ chunks: [PCMBuffer.Chunk], replayCoverageAtRisk: Bool) {
        guard !chunks.isEmpty else { return }
        let timestamp = now
        lock.lock()
        let report = evictionAccumulator.record(
            chunks.compactMap(\.sequenceNumber),
            replayCoverageAtRisk: replayCoverageAtRisk,
            at: timestamp)
        lock.unlock()
        guard let report else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
            guard !stopped else { return }
            self.handle(report)
        }
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
            jlog("Jarvis audio witness [\(speaker.rawValue), \(boundary.rawValue)] "
                 + "@\(Self.seconds(snapshot.emittedAt)): "
                 + "capture=\(snapshot.capturedChunks)/\(snapshot.capturedSamples), "
                 + "delivery=\(snapshot.deliveredChunks)/\(snapshot.deliveredSamples), "
                 + "pending=\(snapshot.pendingCapturedChunks), active=\(snapshot.localActivityDetected), "
                 + "provider_paths=[\(sockets)]")
        }

        for anomaly in output.anomalies {
            switch anomaly {
            case .captureStalled(let lastCaptureAt, let duration):
                let lastCapture = lastCaptureAt.map(Self.seconds) ?? "never"
                jlog("⚠️ audio continuity [\(speaker.rawValue)] capture stalled for "
                     + "\(Self.seconds(duration)) (last=\(lastCapture))")
                lock.lock()
                let emitStall = !reportedStall
                reportedStall = true
                lock.unlock()
                if emitStall { onCaptureContinuity?(.stalled) }
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
                jlog("⚠️ audio continuity [\(speaker.rawValue)] reconnect replay coverage lost: "
                     + "evicted=\(evictedChunks), sequences=\(first)...\(last)")
            case .localActivityUnmatched(let activeSince, let duration):
                jlog("⚠️ audio continuity [\(speaker.rawValue)] local activity had no provider speech "
                     + "event: since=\(Self.seconds(activeSince)), window=\(Self.seconds(duration))")
            case .serverSpeechObservedAfterUnmatchedActivity(let activeSince, let serverObservedAt):
                jlog("ℹ️ audio continuity [\(speaker.rawValue)] late provider speech event resolved "
                     + "the prior warning: activity_since=\(Self.seconds(activeSince)), "
                     + "server_at=\(Self.seconds(serverObservedAt))")
            }
        }
    }

    private func handle(_ report: ReplayBufferEvictionAccumulator.Report) {
        switch report {
        case .boundedReplayWindowReached(let sequences):
            let first = sequences.first.map(String.init) ?? "unknown"
            let last = sequences.last.map(String.init) ?? "unknown"
            jlog("ℹ️ audio continuity [\(speaker.rawValue)] bounded replay window reached with no "
                 + "active recovery: expired=\(sequences.count), sequences=\(first)...\(last); "
                 + "further steady-state expiry suppressed")
        case .replayCoverageLost(let sequences):
            handle(witness.recordReconnectBufferOverflow(evictedSequences: sequences, at: now))
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.3fs", value)
    }
}
