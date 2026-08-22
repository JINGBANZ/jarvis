import Foundation

/// Provider-neutral owner for finalized transcript delivery and the coaching triggers derived from it.
/// Provider adapters report only final text and whether their own work is unsettled; this coordinator
/// keeps transcript batching, speech gating, and silence backoff identical across providers.
/// `@unchecked Sendable`: `lock` guards every mutable field; collaborators and callbacks are Sendable.
public final class TranscriptionCoachingCoordinator: @unchecked Sendable {
    private let speaker: Speaker
    private let transcript: RollingTranscript
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let transcriptBatchingWindow: TimeInterval
    private let silenceEnabled: Bool
    private let onTurnEnd: @Sendable (_ transcriptBoundary: Int) -> Void
    private let onSilence: @Sendable (TimeInterval) -> Void
    private let onTranscriptionWorkChanged: @Sendable (Bool) -> Void
    /// Injected for the same reason as `CoachDriver`'s: heard speech must land in this session's
    /// log rather than whichever one is globally enabled.
    private let activityLog: ActivityLog

    private let lock = NSLock()
    private let pending = UtteranceBuffer()
    private var silenceBackoff: SilenceBackoff
    private var stopped = true
    private var generation = 0
    private var hasPendingTranscriptionWork = false
    private var pendingTranscriptBoundary: Int?
    private var transcriptBatchRevision = 0
    private var silenceRevision = 0
    private var silencePausedLogged = false

    public init(
        speaker: Speaker,
        transcript: RollingTranscript,
        clock: Clock,
        sessionStart: TimeInterval,
        transcriptBatchingWindow: TimeInterval,
        silenceTimeout: TimeInterval,
        silenceMaxInterval: TimeInterval,
        silenceIdleCutoff: TimeInterval = .infinity,
        silenceEnabled: Bool,
        onTurnEnd: @escaping @Sendable (_ transcriptBoundary: Int) -> Void,
        onSilence: @escaping @Sendable (TimeInterval) -> Void,
        onTranscriptionWorkChanged: @escaping @Sendable (Bool) -> Void,
        activityLog: ActivityLog = .shared
    ) {
        precondition(transcriptBatchingWindow >= 0 && transcriptBatchingWindow.isFinite)
        self.activityLog = activityLog
        self.speaker = speaker
        self.transcript = transcript
        self.clock = clock
        self.sessionStart = sessionStart
        self.transcriptBatchingWindow = transcriptBatchingWindow
        self.silenceEnabled = silenceEnabled
        self.onTurnEnd = onTurnEnd
        self.onSilence = onSilence
        self.onTranscriptionWorkChanged = onTranscriptionWorkChanged
        silenceBackoff = SilenceBackoff(
            base: silenceTimeout,
            maxInterval: silenceMaxInterval,
            idleCutoff: silenceIdleCutoff)
    }

    public func start() {
        lock.lock()
        generation &+= 1
        let generation = generation
        let reportSettled = hasPendingTranscriptionWork
        stopped = false
        hasPendingTranscriptionWork = false
        pendingTranscriptBoundary = nil
        transcriptBatchRevision &+= 1
        silenceRevision &+= 1
        pending.clear()
        lock.unlock()

        if reportSettled { onTranscriptionWorkChanged(false) }
        restartSilenceTimer(generation: generation)
    }

    public func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        generation &+= 1
        transcriptBatchRevision &+= 1
        silenceRevision &+= 1
        let reportSettled = hasPendingTranscriptionWork
        hasPendingTranscriptionWork = false
        pendingTranscriptBoundary = nil
        pending.clear()
        lock.unlock()

        if reportSettled { onTranscriptionWorkChanged(false) }
    }

    /// Normalize and publish one provider-final result. Provider-specific recovery detail remains in
    /// `source`, which is written only to the debug log; Activity receives its closed typed event.
    @discardableResult
    public func recordFinalizedTranscript(
        _ rawText: String,
        spokenAt: TimeInterval?,
        source: String
    ) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        let fallbackTime = max(0, clock.now() - sessionStart)
        let at = spokenAt.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? fallbackTime

        lock.lock()
        guard !stopped else { lock.unlock(); return false }
        let transcriptBoundary = transcript.append(
            .init(speaker: speaker, text: text, at: at))
        pending.append(text)
        pendingTranscriptBoundary = max(pendingTranscriptBoundary ?? 0, transcriptBoundary)
        let generation = generation
        // Activity and model context share the same speech-time chronology. Transcript completion
        // time remains visible in debug, but it must not decide conversation order.
        activityLog.record(
            .heard(speaker: speaker, text: text),
            at: Date(timeIntervalSince1970: sessionStart + at))
        jlog("🗣 heard (\(speaker.rawValue)): \"\(text)\" (\(source))")
        lock.unlock()

        restartSilenceTimer(generation: generation)
        scheduleTranscriptBatch(generation: generation)
        return true
    }

    /// Realtime supplies its complete item/recovery state. Apple supplies its best available
    /// content-free local PCM proxy. A deferred turn resumes when the provider reports no work.
    public func updateTranscriptionWork(_ hasPendingWork: Bool) {
        lock.lock()
        guard !stopped, hasPendingTranscriptionWork != hasPendingWork else {
            lock.unlock()
            return
        }
        hasPendingTranscriptionWork = hasPendingWork
        let generation = generation
        let shouldResume = !hasPendingWork
            && pending.shouldResumeAfterPendingTranscriptionsSettle(
                hasPendingTranscriptions: false)
        lock.unlock()

        onTranscriptionWorkChanged(hasPendingWork)
        if shouldResume { scheduleTranscriptBatch(generation: generation) }
    }

    private func scheduleTranscriptBatch(generation: Int) {
        lock.lock()
        guard !stopped, self.generation == generation else { lock.unlock(); return }
        transcriptBatchRevision &+= 1
        let revision = transcriptBatchRevision
        let window = transcriptBatchingWindow
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + window) { [weak self] in
            self?.publishTranscriptBatch(generation: generation, revision: revision)
        }
    }

    private func publishTranscriptBatch(generation: Int, revision: Int) {
        lock.lock()
        guard !stopped, self.generation == generation,
              transcriptBatchRevision == revision else { lock.unlock(); return }
        let result = pending.drainIfSettled(
            hasPendingTranscriptions: hasPendingTranscriptionWork)
        let transcriptBoundary: Int?
        if case .ready = result {
            transcriptBoundary = pendingTranscriptBoundary
            pendingTranscriptBoundary = nil
        } else {
            transcriptBoundary = nil
        }
        lock.unlock()

        switch result {
        case .empty:
            break
        case .waitingForPendingTranscriptions:
            jlog("… coaching turn waiting for transcription to settle")
        case .ready(_, let fragments):
            if fragments > 1 { jlog("🧩 coalesced \(fragments) fragments into one turn") }
            guard let transcriptBoundary else {
                jlog("Jarvis transcription coordinator: dropped turn without transcript boundary")
                return
            }
            onTurnEnd(transcriptBoundary)
        }
    }

    private func restartSilenceTimer(generation: Int) {
        guard silenceEnabled else { return }
        lock.lock()
        guard !stopped, self.generation == generation else { lock.unlock(); return }
        silenceBackoff.reset()
        silencePausedLogged = false
        silenceRevision &+= 1
        let revision = silenceRevision
        let interval = silenceBackoff.next()
        lock.unlock()
        scheduleSilenceTimer(
            after: interval,
            quietThreshold: interval,
            generation: generation,
            revision: revision)
    }

    private func scheduleSilenceTimer(
        after delay: TimeInterval,
        quietThreshold: TimeInterval,
        generation: Int,
        revision: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.silenceTimerDidFire(
                quietThreshold: quietThreshold,
                generation: generation,
                revision: revision)
        }
    }

    private func silenceTimerDidFire(
        quietThreshold: TimeInterval,
        generation: Int,
        revision: Int
    ) {
        lock.lock()
        guard !stopped, self.generation == generation,
              silenceRevision == revision else { lock.unlock(); return }
        if hasPendingTranscriptionWork {
            lock.unlock()
            scheduleSilenceTimer(
                after: 1,
                quietThreshold: quietThreshold,
                generation: generation,
                revision: revision)
            return
        }

        let quiet = transcript.silenceDuration(now: clock.now() - sessionStart)
        if quiet < quietThreshold {
            silenceBackoff.reset()
            silencePausedLogged = false
            let nextInterval = silenceBackoff.next()
            lock.unlock()
            scheduleSilenceTimer(
                after: nextInterval,
                quietThreshold: nextInterval,
                generation: generation,
                revision: revision)
            return
        }

        let shouldProbe = silenceBackoff.shouldProbe(quietSoFar: quiet)
        let shouldLogPause = !shouldProbe && !silencePausedLogged
        if !shouldProbe { silencePausedLogged = true }
        let nextInterval = silenceBackoff.next()
        lock.unlock()

        if shouldProbe {
            onSilence(quiet)
        } else if shouldLogPause {
            jlog("🤫 quiet for \(Int(quiet))s — pausing silence checks until speech resumes")
        }
        scheduleSilenceTimer(
            after: nextInterval,
            quietThreshold: nextInterval,
            generation: generation,
            revision: revision)
    }
}
