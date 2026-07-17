import Foundation

/// Reconciles the independent events emitted for each Realtime input-audio item.
///
/// Realtime can finish items out of order, and a failed or missing terminal event must not make an
/// entire spoken turn disappear. The ledger therefore keeps streamed deltas and VAD timing keyed by
/// `item_id` until the item completes, fails, or the caller declares its terminal event overdue.
// @unchecked Sendable: all mutable state is guarded by `lock`.
public final class RealtimeTranscriptionLedger: @unchecked Sendable {
    public static let contextGapMarker =
        "[context gap: speech was detected, but its transcript is unavailable]"
    private static let minimumContextGapDurationMilliseconds = 750

    public struct FinalizedItem: Equatable, Sendable {
        public let itemID: String
        public let text: String
        public let spokenAt: TimeInterval?
        public let spokenEndAt: TimeInterval?
        public let recoveredFromDeltas: Bool
        public let isContextGap: Bool
    }

    private struct Item {
        var audioStartMilliseconds: Int?
        var audioEndMilliseconds: Int?
        var timelineOrigin: TimeInterval?
        var deltas = ""
        var speechStopped = false

        var spokenAt: TimeInterval? {
            guard let audioStartMilliseconds, let timelineOrigin else { return nil }
            return timelineOrigin + (TimeInterval(audioStartMilliseconds) / 1_000)
        }

        var spokenEndAt: TimeInterval? {
            guard let audioEndMilliseconds, let timelineOrigin else { return nil }
            return timelineOrigin + (TimeInterval(audioEndMilliseconds) / 1_000)
        }

        var detectedSpeechDurationMilliseconds: Int? {
            guard let audioStartMilliseconds, let audioEndMilliseconds,
                  audioEndMilliseconds >= audioStartMilliseconds else { return nil }
            return audioEndMilliseconds - audioStartMilliseconds
        }
    }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    /// Makes late duplicate terminal events harmless. In particular, a final transcript arriving
    /// after the stopped-without-terminal deadline must not append a second copy of the same turn.
    private var finalizedItemIDs: Set<String> = []
    /// Highest audio-clock boundary belonging to a terminal item in this socket generation. Kept
    /// separately because transcription completions may arrive out of spoken order.
    private var latestFinalizedAudioEndAt: TimeInterval?

    public init() {}

    @discardableResult
    public func recordSpeechStarted(itemID: String, audioStartMilliseconds: Int,
                                    timelineOrigin: TimeInterval) -> Bool {
        guard !itemID.isEmpty, audioStartMilliseconds >= 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !finalizedItemIDs.contains(itemID) else { return false }
        var item = items[itemID] ?? Item()
        item.audioStartMilliseconds = audioStartMilliseconds
        item.timelineOrigin = timelineOrigin
        item.speechStopped = false
        items[itemID] = item
        return true
    }

    /// Returns true when the item is still awaiting a completed/failed event and therefore needs a
    /// caller-owned deadline. A stop event can arrive without a start event, so it creates the item.
    @discardableResult
    public func recordSpeechStopped(itemID: String, audioEndMilliseconds: Int? = nil) -> Bool {
        guard !itemID.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !finalizedItemIDs.contains(itemID) else { return false }
        var item = items[itemID] ?? Item()
        if let audioEndMilliseconds, audioEndMilliseconds >= 0 {
            item.audioEndMilliseconds = audioEndMilliseconds
        }
        item.speechStopped = true
        items[itemID] = item
        return true
    }

    @discardableResult
    public func recordDelta(itemID: String, delta: String) -> Bool {
        guard !itemID.isEmpty, !delta.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !finalizedItemIDs.contains(itemID) else { return false }
        var item = items[itemID] ?? Item()
        item.deltas += delta
        items[itemID] = item
        return true
    }

    /// Final text is authoritative. If it is empty/unusable but streamed text is available, retain
    /// that partial text rather than dropping the spoken turn. A long VAD-confirmed item with neither
    /// becomes an explicit gap; very short/no-timing items stay ignored as ordinary noise blips.
    public func recordCompleted(itemID: String, transcript: String,
                                speaker: Speaker) -> FinalizedItem? {
        guard !itemID.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !finalizedItemIDs.contains(itemID) else { return nil }
        let item = items.removeValue(forKey: itemID) ?? Item()
        finalizedItemIDs.insert(itemID)
        recordFinalizedAudioEndLocked(item.spokenEndAt)

        if let final = RealtimeSession.meaningfulTranscript(transcript, speaker: speaker) {
            return FinalizedItem(itemID: itemID, text: final, spokenAt: item.spokenAt,
                                 spokenEndAt: item.spokenEndAt,
                                 recoveredFromDeltas: false, isContextGap: false)
        }
        guard let partial = RealtimeSession.meaningfulTranscript(item.deltas, speaker: speaker) else {
            guard let duration = item.detectedSpeechDurationMilliseconds,
                  duration >= Self.minimumContextGapDurationMilliseconds else {
                return nil
            }
            return FinalizedItem(itemID: itemID, text: Self.contextGapMarker,
                                 spokenAt: item.spokenAt, spokenEndAt: item.spokenEndAt,
                                 recoveredFromDeltas: false,
                                 isContextGap: true)
        }
        return FinalizedItem(itemID: itemID, text: partial, spokenAt: item.spokenAt,
                             spokenEndAt: item.spokenEndAt,
                             recoveredFromDeltas: true, isContextGap: false)
    }

    /// A failed transcription still represents detected speech. Preserve streamed text when there
    /// is any; otherwise emit an explicit marker so downstream coaching knows its context is partial.
    public func recordFailed(itemID: String, speaker: Speaker) -> FinalizedItem? {
        finalizeInterruptedItem(itemID: itemID, requireSpeechStopped: false, speaker: speaker)
    }

    /// Resolves a speech-stopped item whose completed/failed event never arrived. The caller owns the
    /// timer so this Core type stays Foundation-only and deterministic in tests.
    public func resolveStoppedItemTimeout(itemID: String, speaker: Speaker) -> FinalizedItem? {
        finalizeInterruptedItem(itemID: itemID, requireSpeechStopped: true,
                                suppressShortEmptyItem: true, speaker: speaker)
    }

    /// Resolves a speech-started item whose VAD stop and transcription terminal both disappeared.
    /// This is a much longer caller-owned deadline than the stopped-item deadline because a genuine
    /// utterance can last for minutes.
    public func resolveActiveItemTimeout(itemID: String, speaker: Speaker) -> FinalizedItem? {
        guard !itemID.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !finalizedItemIDs.contains(itemID), let item = items[itemID], !item.speechStopped else {
            return nil
        }
        return finalizeInterruptedItemLocked(itemID: itemID, item: item,
                                              suppressShortEmptyItem: false,
                                              speaker: speaker)
    }

    /// A socket cannot deliver any more events after it fails. Finalize every item still owned by
    /// that socket immediately so no stale "active speech" state leaks into the replacement session.
    public func resolveAllInterruptedItems(speaker: Speaker) -> [FinalizedItem] {
        lock.lock(); defer { lock.unlock() }
        let pending = items
        return pending.compactMap { itemID, item in
            finalizeInterruptedItemLocked(itemID: itemID, item: item,
                                           suppressShortEmptyItem: false,
                                           speaker: speaker)
        }.sorted {
            ($0.spokenAt ?? .greatestFiniteMagnitude) < ($1.spokenAt ?? .greatestFiniteMagnitude)
        }
    }

    public var hasPendingItems: Bool {
        lock.lock(); defer { lock.unlock() }
        return !items.isEmpty
    }

    public var pendingItemCount: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }

    /// Session-relative capture boundary that can leave the reconnect tail safely.
    ///
    /// If any item remains unresolved, retain audio from the earliest such speech start. Once every
    /// earlier item is terminal, advance through the furthest terminal end even when completions
    /// arrived out of order. An item with no start time blocks advancement because its position is
    /// unknowable.
    public var safeReplayDiscardTime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        if items.values.contains(where: { $0.spokenAt == nil }) { return nil }
        if let earliestPending = items.values.compactMap(\.spokenAt).min() {
            return earliestPending
        }
        return latestFinalizedAudioEndAt
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll(keepingCapacity: false)
        finalizedItemIDs.removeAll(keepingCapacity: false)
        latestFinalizedAudioEndAt = nil
    }

    private func finalizeInterruptedItem(itemID: String, requireSpeechStopped: Bool,
                                         suppressShortEmptyItem: Bool = false,
                                         speaker: Speaker) -> FinalizedItem? {
        guard !itemID.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !finalizedItemIDs.contains(itemID) else { return nil }
        let item = items[itemID] ?? Item()
        guard !requireSpeechStopped || item.speechStopped else { return nil }
        return finalizeInterruptedItemLocked(itemID: itemID, item: item,
                                              suppressShortEmptyItem: suppressShortEmptyItem,
                                              speaker: speaker)
    }

    private func finalizeInterruptedItemLocked(itemID: String, item: Item,
                                                suppressShortEmptyItem: Bool,
                                                speaker: Speaker) -> FinalizedItem? {
        items.removeValue(forKey: itemID)
        finalizedItemIDs.insert(itemID)
        recordFinalizedAudioEndLocked(item.spokenEndAt)

        if let partial = RealtimeSession.meaningfulTranscript(item.deltas, speaker: speaker) {
            return FinalizedItem(itemID: itemID, text: partial, spokenAt: item.spokenAt,
                                 spokenEndAt: item.spokenEndAt,
                                 recoveredFromDeltas: true, isContextGap: false)
        }
        // A missing terminal event does not turn a click/typing blip into missing conversational
        // context. Match the completed-event path: only a VAD-confirmed duration long enough to be
        // plausible speech gets a gap marker. The item is still finalized above, so a late terminal
        // event cannot append a duplicate.
        if suppressShortEmptyItem {
            guard let duration = item.detectedSpeechDurationMilliseconds,
                  duration >= Self.minimumContextGapDurationMilliseconds else { return nil }
        }
        return FinalizedItem(itemID: itemID, text: Self.contextGapMarker,
                             spokenAt: item.spokenAt, spokenEndAt: item.spokenEndAt,
                             recoveredFromDeltas: false, isContextGap: true)
    }

    private func recordFinalizedAudioEndLocked(_ end: TimeInterval?) {
        guard let end else { return }
        latestFinalizedAudioEndAt = max(latestFinalizedAudioEndAt ?? end, end)
    }
}
