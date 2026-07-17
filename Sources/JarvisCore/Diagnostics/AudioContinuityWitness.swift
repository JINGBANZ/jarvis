import Foundation

/// Privacy-preserving evidence that captured audio is continuing through local delivery and into a
/// Realtime socket. It retains only content-free metadata: sequence/sample counts, timestamps,
/// counters, socket generations, server audio-clock values, and one local activity bit.
///
/// Callers provide all timestamps and call `poll` while idle, so behavior is deterministic and this
/// type owns no timer. PCM passed to `recordDelivery` is synchronously reduced to an activity decision
/// and is never stored, returned, logged, or converted to text.
///
/// `@unchecked Sendable`: every mutable field, including the activity detector, is protected by
/// `lock`; no borrowed PCM escapes the locked `recordDelivery` call.
public final class AudioContinuityWitness: @unchecked Sendable {
    private struct CapturedChunk {
        let sampleCount: Int
        let capturedAt: TimeInterval
    }

    private struct SocketStats {
        var sendAttempts = 0
        var sendSuccesses = 0
        var sendFailures = 0
        var lastSendSequence: UInt64?
        var lastSendAttemptAt: TimeInterval?
        var lastSendSuccessAt: TimeInterval?
        var lastSendFailureAt: TimeInterval?
        var serverSpeechSignals = 0
        var lastServerSignal: ServerSpeechSignal?
        var lastServerObservedAt: TimeInterval?
        var lastServerAudioTimeMilliseconds: Int?
    }

    private let configuration: Configuration
    private let startedAt: TimeInterval
    private let lock = NSLock()
    private var activityDetector: AdaptiveAudioActivityDetector
    private var nextSnapshotAt: TimeInterval

    private var capturedChunks = 0
    private var capturedSamples = 0
    private var deliveredChunks = 0
    private var deliveredSamples = 0
    private var lastCapturedSequence: UInt64?
    private var lastDeliveredSequence: UInt64?
    private var lastCaptureAt: TimeInterval?
    private var lastDeliveryAt: TimeInterval?
    private var pendingCaptures: [UInt64: CapturedChunk] = [:]
    private var pendingCaptureOrder: [UInt64] = []
    private var pendingCaptureCursor = 0

    private var socketStats: [Int: SocketStats] = [:]
    private var latestSocketGeneration: Int?
    private var serverSpeechActive = false
    /// Session-relative audio-clock position of the latest active server VAD start. Observed arrival
    /// time is insufficient: a delayed terminal/start event for older audio must not match a newer
    /// local-activity episode merely because it arrived later.
    private var activeServerSpeechStartedAt: TimeInterval?

    private var localActivitySince: TimeInterval?
    private var lastLocalActivityAt: TimeInterval?
    private var localActivityMatched = false
    private var captureStallReported = false
    private var deliveryLagReported = false
    private var unmatchedActivityReported = false

    /// All subsequent timestamps must use the same session-relative monotonic clock as `startedAt`.
    public init(configuration: Configuration = .init(), startedAt: TimeInterval) {
        self.configuration = configuration
        self.startedAt = startedAt
        activityDetector = AdaptiveAudioActivityDetector(configuration: configuration.activity)
        nextSnapshotAt = startedAt + configuration.snapshotInterval
    }

    @discardableResult
    public func recordCapture(sequence: UInt64, sampleCount: Int,
                              at timestamp: TimeInterval) -> Output {
        precondition(sampleCount >= 0)
        lock.lock(); defer { lock.unlock() }
        var anomalies: [Anomaly] = []
        let stallReference = lastCaptureAt ?? startedAt
        let stalledFor = max(0, timestamp - stallReference)
        if !captureStallReported, stalledFor >= configuration.captureStallThreshold {
            anomalies.append(.captureStalled(lastCaptureAt: lastCaptureAt, duration: stalledFor))
        }
        captureStallReported = false
        if let previous = lastCapturedSequence, sequence != previous &+ 1 {
            anomalies.append(.sequenceGap(stage: .capture, expected: previous &+ 1,
                                          observed: sequence))
        }
        lastCapturedSequence = sequence
        lastCaptureAt = timestamp
        capturedChunks += 1
        capturedSamples += sampleCount
        if pendingCaptures[sequence] == nil { pendingCaptureOrder.append(sequence) }
        pendingCaptures[sequence] = CapturedChunk(sampleCount: sampleCount, capturedAt: timestamp)
        trimPendingCapturesLocked()
        return finishLocked(at: timestamp, immediate: anomalies)
    }

    /// `pcm16` must be little-endian mono PCM16 for the chunk identified by `sequence`. The bytes are
    /// inspected synchronously for activity and are not assigned to any retained field.
    @discardableResult
    public func recordDelivery(sequence: UInt64, pcm16: Data,
                               at timestamp: TimeInterval) -> Output {
        lock.lock(); defer { lock.unlock() }
        var anomalies: [Anomaly] = []
        let expected = lastDeliveredSequence.map { $0 &+ 1 }
            ?? oldestPendingCaptureLocked()?.sequence
        if let expected, sequence != expected {
            anomalies.append(.sequenceGap(stage: .delivery, expected: expected,
                                          observed: sequence))
        }
        lastDeliveredSequence = sequence
        lastDeliveryAt = timestamp
        deliveredChunks += 1

        let activity = activityDetector.observe(pcm16: pcm16)
        deliveredSamples += activity.sampleCount
        let captured = pendingCaptures.removeValue(forKey: sequence)
        prunePendingCaptureOrderLocked()
        if let captured {
            if captured.sampleCount != activity.sampleCount {
                anomalies.append(.deliverySampleCountMismatch(sequence: sequence,
                                                               captured: captured.sampleCount,
                                                               delivered: activity.sampleCount))
            }
            let lag = max(0, timestamp - captured.capturedAt)
            if lag >= configuration.deliveryLagThreshold {
                if !deliveryLagReported {
                    anomalies.append(.captureToDeliveryLag(sequence: sequence, lag: lag))
                    deliveryLagReported = true
                }
            } else {
                deliveryLagReported = false
            }
            updateLocalActivityLocked(isActive: activity.isActive, at: captured.capturedAt)
        } else {
            anomalies.append(.deliveryWithoutCapture(sequence: sequence))
            updateLocalActivityLocked(isActive: activity.isActive, at: timestamp)
        }
        return finishLocked(at: timestamp, immediate: anomalies)
    }

    @discardableResult
    public func recordSendAttempt(sequence: UInt64, socketGeneration: Int,
                                  at timestamp: TimeInterval) -> Output {
        lock.lock(); defer { lock.unlock() }
        selectSocketGenerationLocked(socketGeneration)
        var stats = socketStats[socketGeneration] ?? SocketStats()
        stats.sendAttempts += 1
        stats.lastSendSequence = sequence
        stats.lastSendAttemptAt = timestamp
        socketStats[socketGeneration] = stats
        return finishLocked(at: timestamp)
    }

    @discardableResult
    public func recordSendSuccess(sequence: UInt64, socketGeneration: Int,
                                  at timestamp: TimeInterval) -> Output {
        lock.lock(); defer { lock.unlock() }
        selectSocketGenerationLocked(socketGeneration)
        var stats = socketStats[socketGeneration] ?? SocketStats()
        stats.sendSuccesses += 1
        stats.lastSendSequence = sequence
        stats.lastSendSuccessAt = timestamp
        socketStats[socketGeneration] = stats
        return finishLocked(at: timestamp)
    }

    @discardableResult
    public func recordSendFailure(sequence: UInt64, socketGeneration: Int,
                                  at timestamp: TimeInterval) -> Output {
        lock.lock(); defer { lock.unlock() }
        selectSocketGenerationLocked(socketGeneration)
        var stats = socketStats[socketGeneration] ?? SocketStats()
        stats.sendFailures += 1
        stats.lastSendSequence = sequence
        stats.lastSendFailureAt = timestamp
        socketStats[socketGeneration] = stats
        return finishLocked(at: timestamp)
    }

    /// Records intentional bounded-buffer eviction without retaining any PCM. This is the point at
    /// which exact replay is no longer possible after an unusually long outage, so it must be visible
    /// in the same continuity evidence as capture, delivery, and transport.
    @discardableResult
    public func recordReconnectBufferOverflow(evictedSequences: [UInt64],
                                              at timestamp: TimeInterval) -> Output {
        guard !evictedSequences.isEmpty else { return poll(at: timestamp) }
        lock.lock(); defer { lock.unlock() }
        return finishLocked(at: timestamp, immediate: [
            .reconnectBufferOverflow(
                evictedChunks: evictedSequences.count,
                firstSequence: evictedSequences.first,
                lastSequence: evictedSequences.last),
        ])
    }

    @discardableResult
    public func recordServerSpeech(_ signal: ServerSpeechSignal,
                                   audioTimeMilliseconds: Int?, socketGeneration: Int,
                                   sessionAudioTime: TimeInterval? = nil,
                                   observedAt timestamp: TimeInterval) -> Output {
        precondition(audioTimeMilliseconds == nil || audioTimeMilliseconds! >= 0)
        precondition(sessionAudioTime == nil || sessionAudioTime!.isFinite)
        lock.lock(); defer { lock.unlock() }
        selectSocketGenerationLocked(socketGeneration)
        var stats = socketStats[socketGeneration] ?? SocketStats()
        stats.serverSpeechSignals += 1
        stats.lastServerSignal = signal
        stats.lastServerObservedAt = timestamp
        if let audioTimeMilliseconds { stats.lastServerAudioTimeMilliseconds = audioTimeMilliseconds }
        socketStats[socketGeneration] = stats

        var anomalies: [Anomaly] = []
        if latestSocketGeneration == socketGeneration {
            switch signal {
            case .speechStarted:
                serverSpeechActive = true
                activeServerSpeechStartedAt = sessionAudioTime
                if let activeSince = localActivitySince,
                   serverStartMatchesCurrentActivityLocked(sessionAudioTime) {
                    if unmatchedActivityReported {
                        anomalies.append(.serverSpeechObservedAfterUnmatchedActivity(
                            activeSince: activeSince, serverObservedAt: timestamp))
                    }
                    localActivityMatched = true
                    unmatchedActivityReported = false
                }
            case .speechStopped:
                serverSpeechActive = false
                activeServerSpeechStartedAt = nil
            case .transcriptionDelta, .transcriptionCompleted, .transcriptionFailed:
                // Terminal/delta events may arrive late for an earlier item. They remain useful
                // transport metadata but are not evidence that the current local episode matched.
                break
            }
        }
        return finishLocked(at: timestamp, immediate: anomalies)
    }

    /// Call while no other observations are arriving so stalls, grace-window anomalies, and periodic
    /// snapshots still advance. `forceSnapshot` is useful for a final session summary.
    public func poll(at timestamp: TimeInterval, forceSnapshot: Bool = false) -> Output {
        lock.lock(); defer { lock.unlock() }
        return finishLocked(at: timestamp, forceSnapshot: forceSnapshot)
    }

    private func updateLocalActivityLocked(isActive: Bool, at timestamp: TimeInterval) {
        if isActive {
            // Start a new episode after a reported/matched one even if no explicit quiet chunk was
            // delivered between them. Short sub-threshold gaps remain inside one spoken phrase.
            if let activeSince = localActivitySince, let lastActiveAt = lastLocalActivityAt,
               timestamp - lastActiveAt > configuration.activityHangover {
                let observed = lastActiveAt - activeSince
                if localActivityMatched || unmatchedActivityReported
                    || observed < configuration.sustainedActivityDuration {
                    localActivitySince = nil
                    lastLocalActivityAt = nil
                    localActivityMatched = false
                    unmatchedActivityReported = false
                }
            }
            if localActivitySince == nil {
                localActivitySince = timestamp
                lastLocalActivityAt = timestamp
                localActivityMatched = serverSpeechActive
                    && serverStartMatchesCurrentActivityLocked(activeServerSpeechStartedAt)
                unmatchedActivityReported = false
            }
            lastLocalActivityAt = timestamp
        } else {
            // Do not erase an unmatched episode as soon as speech ends: the whole purpose of the
            // grace window is to notice that local activity ended without any server speech event.
            // Matched/reported episodes can be released once their short hangover has elapsed.
            if let lastLocalActivityAt,
               timestamp - lastLocalActivityAt >= configuration.activityHangover,
               localActivityMatched || unmatchedActivityReported {
                localActivitySince = nil
                self.lastLocalActivityAt = nil
                localActivityMatched = false
                unmatchedActivityReported = false
            }
        }
    }

    private func selectSocketGenerationLocked(_ generation: Int) {
        guard latestSocketGeneration == nil || generation > latestSocketGeneration! else { return }
        latestSocketGeneration = generation
        serverSpeechActive = false
        activeServerSpeechStartedAt = nil
        if localActivitySince != nil {
            localActivityMatched = false
            // Keep an already-reported warning latched across reconnects so one continuous local
            // activity episode cannot add duplicate transcript markers for each socket generation.
        }
    }

    private func serverStartMatchesCurrentActivityLocked(_ serverStart: TimeInterval?) -> Bool {
        guard let serverStart, let activeSince = localActivitySince,
              let lastActiveAt = lastLocalActivityAt else { return false }
        let tolerance = configuration.activityHangover
        return serverStart >= activeSince - tolerance
            && serverStart <= lastActiveAt + tolerance
    }

    private func finishLocked(at timestamp: TimeInterval, immediate: [Anomaly] = [],
                              forceSnapshot: Bool = false) -> Output {
        var anomalies = immediate
        let captureReference = lastCaptureAt ?? startedAt
        let stalledFor = max(0, timestamp - captureReference)
        if stalledFor >= configuration.captureStallThreshold, !captureStallReported {
            anomalies.append(.captureStalled(lastCaptureAt: lastCaptureAt, duration: stalledFor))
            captureStallReported = true
        }

        if let pending = oldestPendingCaptureLocked(), !deliveryLagReported {
            let lag = max(0, timestamp - pending.chunk.capturedAt)
            if lag >= configuration.deliveryLagThreshold {
                anomalies.append(.captureToDeliveryLag(sequence: pending.sequence, lag: lag))
                deliveryLagReported = true
            }
        }

        if let activeSince = localActivitySince, let lastActiveAt = lastLocalActivityAt,
           !localActivityMatched,
           !unmatchedActivityReported {
            let duration = max(0, timestamp - activeSince)
            let observedActivityDuration = max(0, lastActiveAt - activeSince)
            if observedActivityDuration >= configuration.sustainedActivityDuration,
               timestamp - lastActiveAt >= configuration.serverSpeechGrace {
                anomalies.append(.localActivityUnmatched(activeSince: activeSince, duration: duration))
                unmatchedActivityReported = true
            }
        }

        let snapshot: Snapshot?
        if forceSnapshot || timestamp >= nextSnapshotAt {
            snapshot = snapshotLocked(at: timestamp)
            if timestamp >= nextSnapshotAt {
                let elapsed = max(0, timestamp - startedAt)
                let periods = floor(elapsed / configuration.snapshotInterval) + 1
                nextSnapshotAt = startedAt + periods * configuration.snapshotInterval
            }
        } else {
            snapshot = nil
        }
        return Output(snapshot: snapshot, anomalies: anomalies)
    }

    private func snapshotLocked(at timestamp: TimeInterval) -> Snapshot {
        let generations = socketStats.keys.sorted().map { generation in
            let stats = socketStats[generation]!
            return SocketGenerationSnapshot(
                generation: generation,
                sendAttempts: stats.sendAttempts,
                sendSuccesses: stats.sendSuccesses,
                sendFailures: stats.sendFailures,
                lastSendSequence: stats.lastSendSequence,
                lastSendAttemptAt: stats.lastSendAttemptAt,
                lastSendSuccessAt: stats.lastSendSuccessAt,
                lastSendFailureAt: stats.lastSendFailureAt,
                serverSpeechSignals: stats.serverSpeechSignals,
                lastServerSignal: stats.lastServerSignal,
                lastServerObservedAt: stats.lastServerObservedAt,
                lastServerAudioTimeMilliseconds: stats.lastServerAudioTimeMilliseconds
            )
        }
        return Snapshot(
            emittedAt: timestamp,
            capturedChunks: capturedChunks,
            capturedSamples: capturedSamples,
            deliveredChunks: deliveredChunks,
            deliveredSamples: deliveredSamples,
            lastCapturedSequence: lastCapturedSequence,
            lastDeliveredSequence: lastDeliveredSequence,
            lastCaptureAt: lastCaptureAt,
            lastDeliveryAt: lastDeliveryAt,
            pendingCapturedChunks: pendingCaptures.count,
            localActivityDetected: activityDetector.isActive,
            localActivitySince: localActivitySince,
            lastLocalActivityAt: lastLocalActivityAt,
            latestSocketGeneration: latestSocketGeneration,
            socketGenerations: generations
        )
    }

    private func trimPendingCapturesLocked() {
        prunePendingCaptureOrderLocked()
        while pendingCaptures.count > configuration.maximumPendingCaptures,
              pendingCaptureCursor < pendingCaptureOrder.count {
            pendingCaptures.removeValue(forKey: pendingCaptureOrder[pendingCaptureCursor])
            pendingCaptureCursor += 1
            prunePendingCaptureOrderLocked()
        }
    }

    private func oldestPendingCaptureLocked() -> (sequence: UInt64, chunk: CapturedChunk)? {
        prunePendingCaptureOrderLocked()
        guard pendingCaptureCursor < pendingCaptureOrder.count else { return nil }
        let sequence = pendingCaptureOrder[pendingCaptureCursor]
        guard let chunk = pendingCaptures[sequence] else { return nil }
        return (sequence, chunk)
    }

    private func prunePendingCaptureOrderLocked() {
        while pendingCaptureCursor < pendingCaptureOrder.count,
              pendingCaptures[pendingCaptureOrder[pendingCaptureCursor]] == nil {
            pendingCaptureCursor += 1
        }
        if pendingCaptureCursor >= 1_024 {
            pendingCaptureOrder.removeFirst(pendingCaptureCursor)
            pendingCaptureCursor = 0
        }
    }
}
