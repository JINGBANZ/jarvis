import Foundation
import JarvisCore

/// Coordinates Realtime item state, recovery fallback, and terminal deadlines.
/// The WebSocket owner parses events and validates transport generations; this type keeps the
/// provider-specific lifecycle atomic while the shared Core coordinator owns coaching behavior.
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
    private let coachingCoordinator: TranscriptionCoachingCoordinator
    private let terminalTimeout: TimeInterval
    private let activeTimeout: TimeInterval
    private let isCurrentGeneration: @Sendable (Int) -> Bool
    private let isReady: @Sendable (Int) -> Bool
    private let discardConfirmedAudio: @Sendable (TimeInterval) -> Void
    private let onFinalizedItem: @Sendable (RealtimeTranscriptionLedger.FinalizedItem) -> Void

    private let lock = NSLock()
    private let ledger = RealtimeTranscriptionLedger()
    private var reconnectRecovery = RealtimeReconnectTranscriptionRecovery()
    private var replayRecoveryTimer: Timer?
    private var stopped = true
    private var localSpeechActive = false
    private var unboundLocalTurnCount = 0
    /// Local commits have an exact boundary but must keep their PCM replayable until a terminal
    /// transcript arrives. On reconnect, do not let ledger finalization retire that audio first.
    private var locallyCommittedItemIDs: Set<String> = []

    init(speaker: Speaker, coachingCoordinator: TranscriptionCoachingCoordinator,
         terminalTimeout: TimeInterval, activeTimeout: TimeInterval,
         isCurrentGeneration: @escaping @Sendable (Int) -> Bool,
         isReady: @escaping @Sendable (Int) -> Bool,
         discardConfirmedAudio: @escaping @Sendable (TimeInterval) -> Void,
         onFinalizedItem: @escaping @Sendable (
            RealtimeTranscriptionLedger.FinalizedItem
         ) -> Void) {
        self.speaker = speaker
        self.coachingCoordinator = coachingCoordinator
        self.terminalTimeout = terminalTimeout
        self.activeTimeout = activeTimeout
        self.isCurrentGeneration = isCurrentGeneration
        self.isReady = isReady
        self.discardConfirmedAudio = discardConfirmedAudio
        self.onFinalizedItem = onFinalizedItem
    }

    func start() {
        lock.lock()
        stopped = false
        ledger.clear()
        reconnectRecovery.clear()
        localSpeechActive = false
        unboundLocalTurnCount = 0
        locallyCommittedItemIDs.removeAll(keepingCapacity: false)
        lock.unlock()
        coachingCoordinator.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let replayRecoveryTimer = self.replayRecoveryTimer
        self.replayRecoveryTimer = nil
        ledger.clear()
        reconnectRecovery.clear()
        localSpeechActive = false
        unboundLocalTurnCount = 0
        locallyCommittedItemIDs.removeAll(keepingCapacity: false)
        lock.unlock()
        coachingCoordinator.stop()
        DispatchQueue.main.async {
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
        updateCoachingActivityLocked()
        lock.unlock()
        if didStart { scheduleActiveDeadline(itemID: itemID, socketGeneration: socketGeneration) }
        return didStart
    }

    func recordLocalSpeechStarted() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        localSpeechActive = true
        updateCoachingActivityLocked()
        lock.unlock()
    }

    func recordLocalSpeechEnded() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        localSpeechActive = false
        unboundLocalTurnCount += 1
        updateCoachingActivityLocked()
        lock.unlock()
    }

    /// Associate an explicit-commit acknowledgement with its local timing boundary. The item then
    /// follows the same delta/final/deadline lifecycle as a server-VAD item.
    func recordCommittedLocalTurn(
        itemID: String,
        startedAt: TimeInterval,
        committedThroughAt: TimeInterval,
        consumesUnboundTurn: Bool,
        socketGeneration: Int
    ) -> Bool {
        lock.lock()
        guard !stopped, isCurrentGeneration(socketGeneration) else {
            lock.unlock(); return false
        }
        let startMilliseconds = max(0, Int((startedAt * 1_000).rounded()))
        let endMilliseconds = max(startMilliseconds, Int((committedThroughAt * 1_000).rounded()))
        let didStart = ledger.recordSpeechStarted(
            itemID: itemID,
            audioStartMilliseconds: startMilliseconds,
            timelineOrigin: 0)
        let didStop = ledger.recordSpeechStopped(
            itemID: itemID,
            audioEndMilliseconds: endMilliseconds)
        if didStart || didStop { locallyCommittedItemIDs.insert(itemID) }
        if consumesUnboundTurn, unboundLocalTurnCount > 0 { unboundLocalTurnCount -= 1 }
        discardServerConfirmedAudioLocked()
        updateCoachingActivityLocked()
        lock.unlock()
        if didStart && !didStop {
            scheduleActiveDeadline(itemID: itemID, socketGeneration: socketGeneration)
        }
        if didStop { scheduleTerminalDeadline(itemID: itemID, socketGeneration: socketGeneration) }
        return didStart || didStop
    }

    func discardUnboundLocalTurns(_ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        unboundLocalTurnCount = max(0, unboundLocalTurnCount - count)
        updateCoachingActivityLocked()
        lock.unlock()
    }

    /// Returns true when a delta created an item and therefore armed a new active deadline.
    func recordDelta(itemID: String, delta: String, socketGeneration: Int) -> Bool {
        lock.lock()
        guard !stopped, isCurrentGeneration(socketGeneration) else { lock.unlock(); return false }
        let created = ledger.recordDelta(itemID: itemID, delta: delta)
        updateCoachingActivityLocked()
        lock.unlock()
        if created { scheduleActiveDeadline(itemID: itemID, socketGeneration: socketGeneration) }
        return created
    }

    func recordCompleted(itemID: String, transcript text: String, socketGeneration: Int) {
        lock.lock()
        guard !stopped, isCurrentGeneration(socketGeneration) else { lock.unlock(); return }
        let item = ledger.recordCompleted(itemID: itemID, transcript: text, speaker: speaker)
        locallyCommittedItemIDs.remove(itemID)
        discardServerConfirmedAudioLocked()
        let handled = reconcileReplacementItemLocked(
            item, reason: item?.recoveredFromDeltas == true ? "completed without usable final" : nil)
        if !handled {
            jlog("Jarvis realtime [\(speaker.rawValue)] transcription completed "
                 + "with no usable text (item \(itemID))")
        }
        updateCoachingActivityLocked()
        lock.unlock()
    }

    func recordFailed(itemID: String, error: String, socketGeneration: Int) {
        lock.lock()
        guard !stopped, isCurrentGeneration(socketGeneration) else { lock.unlock(); return }
        let item = ledger.recordFailed(itemID: itemID, speaker: speaker)
        locallyCommittedItemIDs.remove(itemID)
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
        updateCoachingActivityLocked()
        lock.unlock()
    }

    func recordSpeechStopped(itemID: String, audioEndMilliseconds: Int?,
                             socketGeneration: Int) -> Bool {
        lock.lock()
        guard !stopped, isCurrentGeneration(socketGeneration) else { lock.unlock(); return false }
        let didStop = ledger.recordSpeechStopped(
            itemID: itemID, audioEndMilliseconds: audioEndMilliseconds)
        discardServerConfirmedAudioLocked()
        updateCoachingActivityLocked()
        lock.unlock()
        if didStop { scheduleTerminalDeadline(itemID: itemID, socketGeneration: socketGeneration) }
        return didStop
    }

    func beginReconnectRecovery(replayAvailable: Bool) -> Int {
        lock.lock()
        let preserveLocalReplayAudio = !locallyCommittedItemIDs.isEmpty
        let duplicateRiskItems = ledger.replayDuplicateRiskItemCount
        let interruptedItems = ledger.resolveAllInterruptedItems(speaker: speaker)
        if !preserveLocalReplayAudio { discardServerConfirmedAudioLocked() }
        locallyCommittedItemIDs.removeAll(keepingCapacity: true)
        reconnectRecovery.begin(interruptedItems: interruptedItems,
                                duplicateRiskItemCount: duplicateRiskItems,
                                replayAvailable: replayAvailable)
        let count = reconnectRecovery.unresolvedItemCount
        updateCoachingActivityLocked()
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
        updateCoachingActivityLocked()
        lock.unlock()
        if waiting { scheduleReplayRecoveryDeadline(socketGeneration: socketGeneration) }
        return .init(unresolvedItems: unresolvedItems, fallbackItems: fallbackItems.count,
                     waitingForReplay: waiting)
    }

    @discardableResult
    func recordReplayCoverageLoss() -> Bool {
        lock.lock()
        let recoveryWasActive = reconnectRecovery.isActive
        let fallbackItems = reconnectRecovery.recordCoverageLoss()
        for item in fallbackItems { appendFinalizedItemLocked(item, reason: "replay coverage lost") }
        updateCoachingActivityLocked()
        lock.unlock()
        if !fallbackItems.isEmpty { cancelReplayRecoveryDeadline() }
        return recoveryWasActive
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
        updateCoachingActivityLocked()
        lock.unlock()
        cancelReplayRecoveryDeadline()
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
                self.updateCoachingActivityLocked()
                self.lock.unlock()
                if handled {
                    jlog("Jarvis realtime [\(self.speaker.rawValue)] replay recovery settled after "
                         + "\(timeout)s terminal timeout (item \(itemID))")
                }
                return
            }
            let recovery = item.recoveredFromDeltas
                ? "salvaged streamed text" : "recorded diagnostic; no transcript available"
            self.locallyCommittedItemIDs.remove(itemID)
            self.discardServerConfirmedAudioLocked()
            jlog("Jarvis realtime [\(self.speaker.rawValue)] transcription terminal timed out "
                 + "after \(timeout)s (item \(itemID)); \(recovery)")
            _ = self.reconcileReplacementItemLocked(item, reason: "terminal timeout")
            self.updateCoachingActivityLocked()
            self.lock.unlock()
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
            self.locallyCommittedItemIDs.remove(itemID)
            self.discardServerConfirmedAudioLocked()
            jlog("Jarvis realtime [\(self.speaker.rawValue)] active transcription timed out "
                 + "after \(timeout)s (item \(itemID)); \(recovery)")
            _ = self.reconcileReplacementItemLocked(item, reason: "active-item timeout")
            self.updateCoachingActivityLocked()
            self.lock.unlock()
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
                self.updateCoachingActivityLocked()
                self.lock.unlock()
                if !fallbackItems.isEmpty {
                    jlog("Jarvis realtime [\(self.speaker.rawValue)] replacement replay produced no "
                         + "terminal event after \(timeout)s; salvaged \(fallbackItems.count) item(s)")
                }
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
        onFinalizedItem(item)
        guard let text = item.text else {
            let detail = reason.map { ", after \($0)" } ?? ""
            jlog("⚠️ transcription unavailable (\(speaker.rawValue), item \(item.itemID)\(detail)); "
                 + "diagnostic only")
            return
        }
        let detail = reason.map { ", recovered after \($0)" } ?? ""
        coachingCoordinator.recordFinalizedTranscript(
            text,
            spokenAt: item.spokenAt,
            source: "item \(item.itemID)\(detail)")
    }

    /// The retry gate represents an unsettled utterance, not only the VAD interval. Publish while
    /// holding `lock` so concurrent socket and timeout callbacks cannot reorder state transitions.
    private func updateCoachingActivityLocked() {
        coachingCoordinator.updateActivity(hasPendingWorkLocked)
    }

    private var hasPendingWorkLocked: Bool {
        ledger.hasPendingItems || reconnectRecovery.blocksCoaching
            || localSpeechActive || unboundLocalTurnCount > 0
    }
}
