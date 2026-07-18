import Foundation

/// Holds transcription fallback evidence while a replacement Realtime socket replays audio.
///
/// Already-delivered items whose end timing was missing must be suppressed if replay creates them
/// again. Interrupted items remain a turn barrier until replacement terminal events arrive; their
/// streamed deltas are used only if exact replay coverage is lost or the replacement never settles.
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

    public init() {}

    public var isActive: Bool {
        duplicateRiskCount > 0 || !interruptedFallbackItems.isEmpty
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
        replayAvailable: Bool
    ) {
        guard !isActive else { return }
        duplicateRiskCount = max(0, duplicateRiskItemCount)
        interruptedFallbackItems = interruptedItems
        self.replayAvailable = replayAvailable
        replacementReady = false
        coverageLost = false
    }

    /// Returns fallback items immediately when no authoritative replacement can arrive.
    public mutating func markReplacementReady() -> [RealtimeTranscriptionLedger.FinalizedItem] {
        replacementReady = true
        guard !replayAvailable || coverageLost else { return [] }
        return abandonReplay()
    }

    /// Records loss of any part of the bounded replay window. If the replacement is already ready,
    /// release retained deltas now instead of waiting for terminal events whose PCM was evicted.
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
    }

    private mutating func abandonReplay() -> [RealtimeTranscriptionLedger.FinalizedItem] {
        let fallback = interruptedFallbackItems
        clear()
        return fallback
    }

    private mutating func finishIfSettled() {
        guard duplicateRiskCount == 0, interruptedFallbackItems.isEmpty else { return }
        clear()
    }
}
