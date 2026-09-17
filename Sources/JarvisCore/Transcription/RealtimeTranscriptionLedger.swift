import Foundation

/// Realtime can finish items out of order or never, so deltas and VAD timing stay keyed by
/// `item_id` until a terminal event or a caller-declared timeout. A lost terminal event must not
/// drop a turn.
// @unchecked Sendable: all mutable state is guarded by `lock`.
public final class RealtimeTranscriptionLedger: @unchecked Sendable {
    private static let minimumContextGapDurationMilliseconds = 750

    public struct FinalizedItem: Equatable, Sendable {
        public let itemID: String
        public let text: String?
        public let spokenAt: TimeInterval?
        public let spokenEndAt: TimeInterval?
        public let recoveredFromDeltas: Bool
        public let isTranscriptUnavailable: Bool
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
    /// A final transcript arriving after a timeout must not append a second copy of the turn.
    private var finalizedItemIDs: Set<String> = []
    /// Tracked separately because completions may arrive out of spoken order.
    private var latestFinalizedAudioEndAt: TimeInterval?
    /// Finalized items without `audio_end_ms`. A later VAD start proves where each ended; guessing
    /// from terminal arrival time could discard newer speech.
    private var finalizedStartsAwaitingLaterBoundary: [TimeInterval] = []

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
        let spokenAt = item.spokenAt
        if let spokenAt {
            let resolvedStarts = finalizedStartsAwaitingLaterBoundary.filter { $0 < spokenAt }
            if !resolvedStarts.isEmpty {
                latestFinalizedAudioEndAt = max(latestFinalizedAudioEndAt ?? spokenAt, spokenAt)
                finalizedStartsAwaitingLaterBoundary.removeAll { $0 < spokenAt }
            }
        }
        // Events can arrive out of VAD order. A late start adds timing but must not reopen an item
        // that already received speech_stopped.
        items[itemID] = item
        return true
    }

    /// True when the item still awaits a terminal event and needs a caller-owned deadline. A stop
    /// can arrive without a start, so this may create the item.
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

    /// True only when this delta creates the item, so the caller arms one backstop timer, not one
    /// per delta.
    @discardableResult
    public func recordDelta(itemID: String, delta: String) -> Bool {
        guard !itemID.isEmpty, !delta.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !finalizedItemIDs.contains(itemID) else { return false }
        let createdItem = items[itemID] == nil
        var item = items[itemID] ?? Item()
        item.deltas += delta
        items[itemID] = item
        return createdItem
    }

    /// Unusable final text falls back to streamed deltas. With neither, long VAD-confirmed speech
    /// returns a text-less item and a short or untimed blip returns nil.
    public func recordCompleted(itemID: String, transcript: String,
                                speaker: Speaker) -> FinalizedItem? {
        guard !itemID.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !finalizedItemIDs.contains(itemID) else { return nil }
        let item = items.removeValue(forKey: itemID) ?? Item()
        finalizedItemIDs.insert(itemID)
        recordFinalizedAudioBoundaryLocked(item)

        if let final = TranscriptFiltering.meaningfulTranscript(transcript, speaker: speaker) {
            return FinalizedItem(itemID: itemID, text: final, spokenAt: item.spokenAt,
                                 spokenEndAt: item.spokenEndAt,
                                 recoveredFromDeltas: false, isTranscriptUnavailable: false)
        }
        guard let partial = TranscriptFiltering.meaningfulTranscript(item.deltas, speaker: speaker) else {
            guard let duration = item.detectedSpeechDurationMilliseconds,
                  duration >= Self.minimumContextGapDurationMilliseconds else {
                return nil
            }
            return FinalizedItem(itemID: itemID, text: nil,
                                 spokenAt: item.spokenAt, spokenEndAt: item.spokenEndAt,
                                 recoveredFromDeltas: false,
                                 isTranscriptUnavailable: true)
        }
        return FinalizedItem(itemID: itemID, text: partial, spokenAt: item.spokenAt,
                             spokenEndAt: item.spokenEndAt,
                             recoveredFromDeltas: true, isTranscriptUnavailable: false)
    }

    public func recordFailed(itemID: String, speaker: Speaker) -> FinalizedItem? {
        finalizeInterruptedItem(itemID: itemID, requireSpeechStopped: false,
                                suppressShortEmptyItem: true, speaker: speaker)
    }

    public func resolveStoppedItemTimeout(itemID: String, speaker: Speaker) -> FinalizedItem? {
        finalizeInterruptedItem(itemID: itemID, requireSpeechStopped: true,
                                suppressShortEmptyItem: true, speaker: speaker)
    }

    /// Needs a much longer deadline than the stopped-item one: a real utterance can last minutes.
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

    /// Call when the socket fails, so no stale active speech leaks into the replacement session.
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

    public var hasActiveSpeech: Bool {
        lock.lock(); defer { lock.unlock() }
        return items.values.contains { !$0.speechStopped }
    }

    public var pendingItemCount: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }

    /// Appended items with no end time that replay will repeat, so recovery suppresses that many
    /// replacement items.
    public var replayDuplicateRiskItemCount: Int {
        lock.lock(); defer { lock.unlock() }
        return finalizedStartsAwaitingLaterBoundary.count
    }

    /// Session-relative. Nil while any pending item has no start time; otherwise the earliest
    /// pending start, or the furthest terminal end once nothing earlier is pending.
    public var safeReplayDiscardTime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        if items.values.contains(where: { $0.spokenAt == nil }) { return nil }
        if let earliestPending = items.values.compactMap(\.spokenAt).min() {
            return earliestPending
        }
        if let unresolvedStart = finalizedStartsAwaitingLaterBoundary.min() {
            return min(latestFinalizedAudioEndAt ?? unresolvedStart, unresolvedStart)
        }
        return latestFinalizedAudioEndAt
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll(keepingCapacity: false)
        finalizedItemIDs.removeAll(keepingCapacity: false)
        latestFinalizedAudioEndAt = nil
        finalizedStartsAwaitingLaterBoundary.removeAll(keepingCapacity: false)
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
        recordFinalizedAudioBoundaryLocked(item)

        if let partial = TranscriptFiltering.meaningfulTranscript(item.deltas, speaker: speaker) {
            return FinalizedItem(itemID: itemID, text: partial, spokenAt: item.spokenAt,
                                 spokenEndAt: item.spokenEndAt,
                                 recoveredFromDeltas: true, isTranscriptUnavailable: false)
        }
        // As in `recordCompleted`, a short blip returns nil. It is still finalized above, so a late
        // terminal event can't append a duplicate.
        if suppressShortEmptyItem {
            guard let duration = item.detectedSpeechDurationMilliseconds,
                  duration >= Self.minimumContextGapDurationMilliseconds else { return nil }
        }
        return FinalizedItem(itemID: itemID, text: nil,
                             spokenAt: item.spokenAt, spokenEndAt: item.spokenEndAt,
                             recoveredFromDeltas: false, isTranscriptUnavailable: true)
    }

    private func recordFinalizedAudioEndLocked(_ end: TimeInterval?) {
        guard let end else { return }
        latestFinalizedAudioEndAt = max(latestFinalizedAudioEndAt ?? end, end)
    }

    private func recordFinalizedAudioBoundaryLocked(_ item: Item) {
        if let end = item.spokenEndAt {
            recordFinalizedAudioEndLocked(end)
        } else if let start = item.spokenAt {
            finalizedStartsAwaitingLaterBoundary.append(start)
        }
    }
}
