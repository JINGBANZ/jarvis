import Foundation

/// Provider-neutral owner for finalized transcript delivery and the coaching triggers derived from it.
/// Provider adapters report only final text and whether their own work is unsettled; this coordinator
/// keeps turn coalescing, debounce, speech gating, and silence backoff identical across providers.
/// `@unchecked Sendable`: `lock` guards every mutable field; collaborators and callbacks are Sendable.
public final class TranscriptionCoachingCoordinator: @unchecked Sendable {
    private let speaker: Speaker
    private let transcript: RollingTranscript
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let turnDebounce: TimeInterval
    private let silenceEnabled: Bool
    private let onTurnEnd: @Sendable () -> Void
    private let onSilence: @Sendable (TimeInterval) -> Void
    private let onSpeechActivityChanged: @Sendable (Bool) -> Void

    private let lock = NSLock()
    private let pending = UtteranceBuffer()
    private var silenceBackoff: SilenceBackoff
    private var stopped = true
    private var generation = 0
    private var activityPending = false
    private var debounceRevision = 0
    private var silenceRevision = 0
    private var silencePausedLogged = false

    public init(
        speaker: Speaker,
        transcript: RollingTranscript,
        clock: Clock,
        sessionStart: TimeInterval,
        turnDebounce: TimeInterval,
        silenceTimeout: TimeInterval,
        silenceMaxInterval: TimeInterval,
        silenceIdleCutoff: TimeInterval = .infinity,
        silenceEnabled: Bool,
        onTurnEnd: @escaping @Sendable () -> Void,
        onSilence: @escaping @Sendable (TimeInterval) -> Void,
        onSpeechActivityChanged: @escaping @Sendable (Bool) -> Void
    ) {
        precondition(turnDebounce >= 0 && turnDebounce.isFinite)
        self.speaker = speaker
        self.transcript = transcript
        self.clock = clock
        self.sessionStart = sessionStart
        self.turnDebounce = turnDebounce
        self.silenceEnabled = silenceEnabled
        self.onTurnEnd = onTurnEnd
        self.onSilence = onSilence
        self.onSpeechActivityChanged = onSpeechActivityChanged
        silenceBackoff = SilenceBackoff(
            base: silenceTimeout,
            maxInterval: silenceMaxInterval,
            idleCutoff: silenceIdleCutoff)
    }

    public func start() {
        lock.lock()
        generation &+= 1
        let generation = generation
        let reportInactive = activityPending
        stopped = false
        activityPending = false
        debounceRevision &+= 1
        silenceRevision &+= 1
        pending.clear()
        lock.unlock()

        if reportInactive { onSpeechActivityChanged(false) }
        restartSilenceTimer(generation: generation)
    }

    public func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        generation &+= 1
        debounceRevision &+= 1
        silenceRevision &+= 1
        let reportInactive = activityPending
        activityPending = false
        pending.clear()
        lock.unlock()

        if reportInactive { onSpeechActivityChanged(false) }
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
        transcript.append(.init(speaker: speaker, text: text, at: at))
        pending.append(text)
        let generation = generation
        ActivityLog.shared.record(.heard(speaker: speaker, text: text))
        jlog("🗣 heard (\(speaker.rawValue)): \"\(text)\" (\(source))")
        lock.unlock()

        restartSilenceTimer(generation: generation)
        scheduleTurnDebounce(generation: generation)
        return true
    }

    /// `active` is provider-defined: Realtime supplies its complete item/recovery state, while Apple
    /// supplies its content-free local PCM activity. A deferred turn resumes when that work settles.
    public func updateActivity(_ active: Bool) {
        lock.lock()
        guard !stopped, activityPending != active else { lock.unlock(); return }
        activityPending = active
        let generation = generation
        let shouldResume = !active
            && pending.shouldResumeAfterPendingTranscriptionsSettle(
                hasPendingTranscriptions: false)
        lock.unlock()

        onSpeechActivityChanged(active)
        if shouldResume { scheduleTurnDebounce(generation: generation) }
    }

    private func scheduleTurnDebounce(generation: Int) {
        lock.lock()
        guard !stopped, self.generation == generation else { lock.unlock(); return }
        debounceRevision &+= 1
        let revision = debounceRevision
        let delay = turnDebounce
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.fireTurn(generation: generation, revision: revision)
        }
    }

    private func fireTurn(generation: Int, revision: Int) {
        lock.lock()
        guard !stopped, self.generation == generation,
              debounceRevision == revision else { lock.unlock(); return }
        let result = pending.drainIfSettled(hasPendingTranscriptions: activityPending)
        lock.unlock()

        switch result {
        case .empty:
            break
        case .waitingForPendingTranscriptions:
            jlog("… coaching turn waiting for transcription to settle")
        case .ready(_, let fragments):
            if fragments > 1 { jlog("🧩 coalesced \(fragments) fragments into one turn") }
            onTurnEnd()
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
        if activityPending {
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
