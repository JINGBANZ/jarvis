import Foundation

/// Replay can recreate delivered items that lacked an end time, so those are suppressed.
/// Interrupted items block turns until replaced; their deltas are used only if replay coverage is
/// lost or the replacement never settles.
public struct RealtimeReconnectTranscriptionRecovery: Sendable {
    public enum ReplacementAction: Equatable, Sendable {
        case appendReplacement
        case suppressAlreadyDeliveredReplay
        case useFallback(RealtimeTranscriptionLedger.FinalizedItem)
    }

    private var duplicateRiskCount = 0
    private var interruptedFallbackItems: [RealtimeTranscriptionLedger.FinalizedItem] = []
    private var replayAvailable = false
    private var replacementReady = false
    private var coverageLost = false
    /// Audio without a server item has no identity to count, so it holds one barrier until replay
    /// ends.
    private var hasUntrackedReplayAudio = false

    public init() {}

    public var isActive: Bool {
        duplicateRiskCount > 0 || !interruptedFallbackItems.isEmpty
            || hasUntrackedReplayAudio
    }

    public var blocksCoaching: Bool {
        isActive
    }

    public var unresolvedItemCount: Int {
        duplicateRiskCount + interruptedFallbackItems.count
    }

    public mutating func begin(
        interruptedItems: [RealtimeTranscriptionLedger.FinalizedItem],
        duplicateRiskItemCount: Int,
        replayAvailable: Bool,
        hasUntrackedReplayAudio: Bool = false
    ) {
        // Accumulate: a replacement can fail before the prior recovery settles.
        duplicateRiskCount += max(0, duplicateRiskItemCount)
        interruptedFallbackItems.append(contentsOf: interruptedItems)
        self.replayAvailable = replayAvailable
        self.hasUntrackedReplayAudio = self.hasUntrackedReplayAudio || hasUntrackedReplayAudio
        replacementReady = false
    }

    /// Audio sent while disconnected can later produce an earlier transcript, so it holds coaching.
    public mutating func recordUntrackedReplayAudio() {
        hasUntrackedReplayAudio = true
        replayAvailable = true
    }

    /// Returns fallback items immediately when no authoritative replacement can arrive.
    public mutating func markReplacementReady() -> [RealtimeTranscriptionLedger.FinalizedItem] {
        replacementReady = true
        guard !replayAvailable || coverageLost else { return [] }
        return abandonReplay()
    }

    /// Once the replacement is ready, releases the fallbacks now: their evicted PCM can't produce
    /// terminal events.
    public mutating func recordCoverageLoss() -> [RealtimeTranscriptionLedger.FinalizedItem] {
        guard isActive else { return [] }
        coverageLost = true
        guard replacementReady else { return [] }
        return abandonReplay()
    }

    public mutating func resolveReplacement(hasUsableText: Bool) -> ReplacementAction {
        guard blocksCoaching else { return .appendReplacement }
        if duplicateRiskCount > 0 {
            duplicateRiskCount -= 1
            finishIfSettled()
            return .suppressAlreadyDeliveredReplay
        }

        guard !interruptedFallbackItems.isEmpty else {
            finishIfSettled()
            return .appendReplacement
        }
        let fallback = interruptedFallbackItems.removeFirst()
        finishIfSettled()
        return hasUsableText ? .appendReplacement : .useFallback(fallback)
    }

    public mutating func timeout() -> [RealtimeTranscriptionLedger.FinalizedItem] {
        abandonReplay()
    }

    public mutating func clear() {
        duplicateRiskCount = 0
        interruptedFallbackItems.removeAll(keepingCapacity: false)
        replayAvailable = false
        replacementReady = false
        coverageLost = false
        hasUntrackedReplayAudio = false
    }

    private mutating func abandonReplay() -> [RealtimeTranscriptionLedger.FinalizedItem] {
        let fallback = interruptedFallbackItems
        clear()
        return fallback
    }

    private mutating func finishIfSettled() {
        guard duplicateRiskCount == 0, interruptedFallbackItems.isEmpty,
              !hasUntrackedReplayAudio else { return }
        clear()
    }
}
