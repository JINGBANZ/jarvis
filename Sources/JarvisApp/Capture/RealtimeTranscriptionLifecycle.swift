import Foundation
import JarvisCore

/// Coordinates Realtime item state, recovery fallback, terminal deadlines, and coaching-turn drain.
/// The WebSocket owner parses events and validates transport generations; this type keeps the
/// transcript lifecycle atomic and testable through its Core ledger/buffer/recovery collaborators.
///
/// `@unchecked Sendable`: every mutable field is guarded by `lock`; timer creation/invalidation is
/// dispatched to the main queue.
final class RealtimeTranscriptionLifecycle: @unchecked Sendable {
    struct ReplacementReadyOutcome {
        let unresolvedItems: Int
        let fallbackItems: Int
        let waitingForReplay: Bool
    }

    private let speaker: Speaker
    private let transcript: RollingTranscript
    private let clock: Clock
    private let sessionStart: TimeInterval
    private let turnDebounce: TimeInterval
    private let terminalTimeout: TimeInterval
    private let activeTimeout: TimeInterval
    private let isCurrentGeneration: @Sendable (Int) -> Bool
    private let isReady: @Sendable (Int) -> Bool
    private let discardConfirmedAudio: @Sendable (TimeInterval) -> Void
    private let resetSilenceTimer: @Sendable () -> Void
    private let onTurnEnd: @Sendable () -> Void
    private let onSpeechActivityChanged: @Sendable (Bool) -> Void

    private let lock = NSLock()
    private let pending = UtteranceBuffer()
    private let ledger = RealtimeTranscriptionLedger()
    private var reconnectRecovery = RealtimeReconnectTranscriptionRecovery()
    private var debounceTimer: Timer?
    private var replayRecoveryTimer: Timer?
    private var stopped = true
    private var reportedSpeechActive = false

    init(speaker: Speaker, transcript: RollingTranscript, clock: Clock,
         sessionStart: TimeInterval, turnDebounce: TimeInterval,
         terminalTimeout: TimeInterval, activeTimeout: TimeInterval,
         isCurrentGeneration: @escaping @Sendable (Int) -> Bool,
         isReady: @escaping @Sendable (Int) -> Bool,
         discardConfirmedAudio: @escaping @Sendable (TimeInterval) -> Void,
         resetSilenceTimer: @escaping @Sendable () -> Void,
         onTurnEnd: @escaping @Sendable () -> Void,
         onSpeechActivityChanged: @escaping @Sendable (Bool) -> Void) {
        self.speaker = speaker
        self.transcript = transcript
        self.clock = clock
        self.sessionStart = sessionStart
        self.turnDebounce = turnDebounce
        self.terminalTimeout = terminalTimeout
        self.activeTimeout = activeTimeout
        self.isCurrentGeneration = isCurrentGeneration
        self.isReady = isReady
        self.discardConfirmedAudio = discardConfirmedAudio
        self.resetSilenceTimer = resetSilenceTimer
        self.onTurnEnd = onTurnEnd
        self.onSpeechActivityChanged = onSpeechActivityChanged
    }

    func start() {
        lock.lock()
        stopped = false
        pending.clear()
        ledger.clear()
        reconnectRecovery.clear()
        emitSpeechActivityChangeLocked()
        lock.unlock()
    }

    var hasUnsettledItems: Bool {
        lock.lock(); defer { lock.unlock() }
        return ledger.hasPendingItems || reconnectRecovery.blocksCoaching
    }

    func stop() {
        lock.lock()
        stopped = true
        let debounceTimer = self.debounceTimer
        let replayRecoveryTimer = self.replayRecoveryTimer
        self.debounceTimer = nil
        self.replayRecoveryTimer = nil
        pending.clear()
        ledger.clear()
        reconnectRecovery.clear()
        emitSpeechActivityChangeLocked()
        lock.unlock()
        DispatchQueue.main.async {
            debounceTimer?.invalidate()
            replayRecoveryTimer?.invalidate()
        }
    }

    func recordSpeechStarted(itemID: String, audioStartMilliseconds: Int,
                             timelineOrigin: TimeInterval, socketGeneration: Int) -> Bool {
        lock.lock()
        guard !stopped, isCurrentGeneration(socketGeneration) else { lock.unlock(); return false }
        let didStart = ledger.recordSpeechStarted(
            itemID: itemID, audioStartMilliseconds: audioStartMilliseconds,
            timelineOrigin: timelineOrigin)
        discardServerConfirmedAudioLocked()
        emitSpeechActivityChangeLocked()
        lock.unlock()
        if didStart { scheduleActiveDeadline(itemID: itemID, socketGeneration: socketGeneration) }
        return didStart
    }

    /// Returns true when a delta created an item and therefore armed a new active deadline.
    func recordDelta(itemID: String, delta: String, socketGeneration: Int) -> Bool {
        lock.lock()
        guard !stopped, isCurrentGeneration(socketGeneration) else { lock.unlock(); return false }
        let created = ledger.recordDelta(itemID: itemID, delta: delta)
        emitSpeechActivityChangeLocked()
        lock.unlock()
        if created { scheduleActiveDeadline(itemID: itemID, socketGeneration: socketGeneration) }
        return created
    }

    func recordCompleted(itemID: String, transcript text: String, socketGeneration: Int) {
        lock.lock()
        guard !stopped, isCurrentGeneration(socketGeneration) else { lock.unlock(); return }
        let item = ledger.recordCompleted(itemID: itemID, transcript: text, speaker: speaker)
        discardServerConfirmedAudioLocked()
        let handled = reconcileReplacementItemLocked(
            item, reason: item?.recoveredFromDeltas == true ? "completed without usable final" : nil)
        if !handled {
            jlog("Jarvis realtime [\(speaker.rawValue)] transcription completed "
                 + "with no usable text (item \(itemID))")
        }
        let shouldResume = shouldResumeDeferredTurnLocked()
        emitSpeechActivityChangeLocked()
        lock.unlock()
        if shouldResume { scheduleTurnDebounce() }
    }

    func recordFailed(itemID: String, error: String, socketGeneration: Int) {
        lock.lock()
        guard !stopped, isCurrentGeneration(socketGeneration) else { lock.unlock(); return }
        let item = ledger.recordFailed(itemID: itemID, speaker: speaker)
        discardServerConfirmedAudioLocked()
        let recovery: String
        if item?.recoveredFromDeltas == true {
            recovery = "salvaged streamed text"
        } else if item?.isTranscriptUnavailable == true {
            recovery = "recorded diagnostic; no transcript available"
        } else {
            recovery = "item was already finalized"
        }
        jlog("Jarvis realtime [\(speaker.rawValue)] transcription failed "
             + "(item \(itemID), \(error)); \(recovery)")
        _ = reconcileReplacementItemLocked(item, reason: "transcription failed")
        let shouldResume = shouldResumeDeferredTurnLocked()
        emitSpeechActivityChangeLocked()
        lock.unlock()
        if shouldResume { scheduleTurnDebounce() }
    }

    func recordSpeechStopped(itemID: String, audioEndMilliseconds: Int?,
                             socketGeneration: Int) -> Bool {
        lock.lock()
        guard !stopped, isCurrentGeneration(socketGeneration) else { lock.unlock(); return false }
        let didStop = ledger.recordSpeechStopped(
            itemID: itemID, audioEndMilliseconds: audioEndMilliseconds)
        discardServerConfirmedAudioLocked()
        emitSpeechActivityChangeLocked()
        lock.unlock()
        if didStop { scheduleTerminalDeadline(itemID: itemID, socketGeneration: socketGeneration) }
        return didStop
    }

    func beginReconnectRecovery(replayAvailable: Bool) -> Int {
        lock.lock()
        let duplicateRiskItems = ledger.replayDuplicateRiskItemCount
        let interruptedItems = ledger.resolveAllInterruptedItems(speaker: speaker)
        discardServerConfirmedAudioLocked()
        reconnectRecovery.begin(interruptedItems: interruptedItems,
                                duplicateRiskItemCount: duplicateRiskItems,
                                replayAvailable: replayAvailable)
        let count = reconnectRecovery.unresolvedItemCount
        emitSpeechActivityChangeLocked()
        lock.unlock()
        return count
    }

    func markReplacementReady(socketGeneration: Int) -> ReplacementReadyOutcome {
        lock.lock()
        let unresolvedItems = reconnectRecovery.unresolvedItemCount
        ledger.clear()
        let fallbackItems = reconnectRecovery.markReplacementReady()
        for item in fallbackItems { appendFinalizedItemLocked(item, reason: "replay unavailable") }
        let waiting = reconnectRecovery.blocksCoaching
        let shouldResume = shouldResumeDeferredTurnLocked()
        emitSpeechActivityChangeLocked()
        lock.unlock()
        if shouldResume { scheduleTurnDebounce() }
        if waiting { scheduleReplayRecoveryDeadline(socketGeneration: socketGeneration) }
        return .init(unresolvedItems: unresolvedItems, fallbackItems: fallbackItems.count,
                     waitingForReplay: waiting)
    }

    func recordReplayCoverageLoss() {
        lock.lock()
        let fallbackItems = reconnectRecovery.recordCoverageLoss()
        for item in fallbackItems { appendFinalizedItemLocked(item, reason: "replay coverage lost") }
        let shouldResume = shouldResumeDeferredTurnLocked()
        emitSpeechActivityChangeLocked()
        lock.unlock()
        if !fallbackItems.isEmpty { cancelReplayRecoveryDeadline() }
        if shouldResume { scheduleTurnDebounce() }
    }

    func finalizeInterrupted(reason: String) {
        lock.lock()
        let items = reconnectRecovery.timeout() + ledger.resolveAllInterruptedItems(speaker: speaker)
        discardServerConfirmedAudioLocked()
        if !items.isEmpty {
            jlog("Jarvis realtime [\(speaker.rawValue)] resolving \(items.count) interrupted "
                 + "transcription item(s) after \(reason)")
            for item in items { appendFinalizedItemLocked(item, reason: reason) }
        }
        let shouldResume = shouldResumeDeferredTurnLocked()
        emitSpeechActivityChangeLocked()
        lock.unlock()
        cancelReplayRecoveryDeadline()
        if shouldResume { scheduleTurnDebounce() }
    }

    private func scheduleTurnDebounce() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.stopped else { return }
            self.debounceTimer?.invalidate()
            self.debounceTimer = Timer.scheduledTimer(
                withTimeInterval: self.turnDebounce, repeats: false
            ) { [weak self] _ in self?.fireTurn() }
        }
    }

    private func fireTurn() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        debounceTimer?.invalidate(); debounceTimer = nil
        let pendingItems = ledger.pendingItemCount
        let replayItems = reconnectRecovery.unresolvedItemCount
        let result = pending.drainIfSettled(
            hasPendingTranscriptions: pendingItems > 0 || reconnectRecovery.blocksCoaching)
        lock.unlock()
        switch result {
        case .empty:
            break
        case .waitingForPendingTranscriptions:
            if replayItems > 0 {
                jlog("… coaching turn waiting for \(replayItems) replayed transcription item(s)")
            } else {
                jlog("… coaching turn waiting for \(pendingItems) active transcription item(s)")
            }
        case .ready(_, let fragments):
            if fragments > 1 { jlog("🧩 coalesced \(fragments) fragments into one turn") }
            onTurnEnd()
        }
    }

    private func scheduleTerminalDeadline(itemID: String, socketGeneration: Int) {
        let timeout = terminalTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.stopped, self.isReady(socketGeneration) else { self.lock.unlock(); return }
            let item = self.ledger.resolveStoppedItemTimeout(itemID: itemID, speaker: self.speaker)
            guard let item else {
                let handled = self.reconcileReplacementItemLocked(
                    nil, reason: "replacement terminal timeout")
                let shouldResume = self.shouldResumeDeferredTurnLocked()
                self.emitSpeechActivityChangeLocked()
                self.lock.unlock()
                if handled {
                    jlog("Jarvis realtime [\(self.speaker.rawValue)] replay recovery settled after "
                         + "\(timeout)s terminal timeout (item \(itemID))")
                }
                if shouldResume { self.scheduleTurnDebounce() }
                return
            }
            let recovery = item.recoveredFromDeltas
                ? "salvaged streamed text" : "recorded diagnostic; no transcript available"
            self.discardServerConfirmedAudioLocked()
            jlog("Jarvis realtime [\(self.speaker.rawValue)] transcription terminal timed out "
                 + "after \(timeout)s (item \(itemID)); \(recovery)")
            _ = self.reconcileReplacementItemLocked(item, reason: "terminal timeout")
            let shouldResume = self.shouldResumeDeferredTurnLocked()
            self.emitSpeechActivityChangeLocked()
            self.lock.unlock()
            if shouldResume { self.scheduleTurnDebounce() }
        }
    }

    private func scheduleActiveDeadline(itemID: String, socketGeneration: Int) {
        let timeout = activeTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.stopped, self.isReady(socketGeneration) else { self.lock.unlock(); return }
            guard let item = self.ledger.resolveActiveItemTimeout(
                itemID: itemID, speaker: self.speaker
            ) else { self.lock.unlock(); return }
            let recovery = item.recoveredFromDeltas
                ? "salvaged streamed text" : "recorded diagnostic; no transcript available"
            self.discardServerConfirmedAudioLocked()
            jlog("Jarvis realtime [\(self.speaker.rawValue)] active transcription timed out "
                 + "after \(timeout)s (item \(itemID)); \(recovery)")
            _ = self.reconcileReplacementItemLocked(item, reason: "active-item timeout")
            let shouldResume = self.shouldResumeDeferredTurnLocked()
            self.emitSpeechActivityChangeLocked()
            self.lock.unlock()
            if shouldResume { self.scheduleTurnDebounce() }
        }
    }

    private func scheduleReplayRecoveryDeadline(socketGeneration: Int) {
        let timeout = terminalTimeout
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let shouldWait = self.reconnectRecovery.blocksCoaching; self.lock.unlock()
            guard shouldWait else { return }
            self.replayRecoveryTimer?.invalidate()
            self.replayRecoveryTimer = Timer.scheduledTimer(
                withTimeInterval: timeout, repeats: false
            ) { [weak self] _ in
                guard let self, self.isReady(socketGeneration) else { return }
                self.lock.lock()
                let fallbackItems = self.reconnectRecovery.timeout()
                for item in fallbackItems {
                    self.appendFinalizedItemLocked(item, reason: "replacement replay timeout")
                }
                let shouldResume = self.shouldResumeDeferredTurnLocked()
                self.emitSpeechActivityChangeLocked()
                self.lock.unlock()
                if !fallbackItems.isEmpty {
                    jlog("Jarvis realtime [\(self.speaker.rawValue)] replacement replay produced no "
                         + "terminal event after \(timeout)s; salvaged \(fallbackItems.count) item(s)")
                }
                if shouldResume { self.scheduleTurnDebounce() }
            }
        }
    }

    private func cancelReplayRecoveryDeadline() {
        DispatchQueue.main.async { [weak self] in
            self?.replayRecoveryTimer?.invalidate()
            self?.replayRecoveryTimer = nil
        }
    }

    private func discardServerConfirmedAudioLocked() {
        guard let boundary = ledger.safeReplayDiscardTime else { return }
        discardConfirmedAudio(boundary)
    }

    @discardableResult
    private func reconcileReplacementItemLocked(
        _ item: RealtimeTranscriptionLedger.FinalizedItem?, reason: String?
    ) -> Bool {
        let recoveryWasActive = reconnectRecovery.isActive
        let action = reconnectRecovery.resolveReplacement(hasUsableText: item?.text != nil)
        let handled: Bool
        switch action {
        case .appendReplacement:
            if let item {
                appendFinalizedItemLocked(item, reason: reason)
                handled = true
            } else {
                handled = false
            }
        case .suppressAlreadyDeliveredReplay:
            jlog("Jarvis realtime [\(speaker.rawValue)] suppressed already-delivered replay "
                 + "transcription (item \(item?.itemID ?? "unknown"))")
            handled = true
        case .useFallback(let fallback):
            appendFinalizedItemLocked(fallback, reason: "replacement transcript unavailable")
            handled = true
        }
        if recoveryWasActive && !reconnectRecovery.isActive { cancelReplayRecoveryDeadline() }
        return handled
    }

    private func appendFinalizedItemLocked(
        _ item: RealtimeTranscriptionLedger.FinalizedItem, reason: String?
    ) {
        guard !stopped else { return }
        let at = item.spokenAt ?? (clock.now() - sessionStart)
        guard let text = item.text else {
            let detail = reason.map { ", after \($0)" } ?? ""
            jlog("⚠️ transcription unavailable (\(speaker.rawValue), item \(item.itemID)\(detail)); "
                 + "diagnostic only")
            return
        }
        transcript.append(.init(speaker: speaker, text: text, at: at))
        let detail = reason.map { ", recovered after \($0)" } ?? ""
        jlog("🗣 heard (\(speaker.rawValue)): \"\(text)\" (item \(item.itemID)\(detail))")
        ActivityLog.shared.record(.heard(speaker: speaker, text: text))
        pending.append(text)
        resetSilenceTimer()
        scheduleTurnDebounce()
    }

    private func shouldResumeDeferredTurnLocked() -> Bool {
        pending.shouldResumeAfterPendingTranscriptionsSettle(
            hasPendingTranscriptions: ledger.hasPendingItems || reconnectRecovery.blocksCoaching)
    }

    /// The retry gate represents an unsettled utterance, not only the VAD interval. Deliver while
    /// holding `lock` so concurrent socket and timeout callbacks cannot reorder state transitions.
    private func emitSpeechActivityChangeLocked() {
        let active = ledger.hasPendingItems || reconnectRecovery.blocksCoaching
        guard active != reportedSpeechActive else { return }
        reportedSpeechActive = active
        onSpeechActivityChanged(active)
    }
}
