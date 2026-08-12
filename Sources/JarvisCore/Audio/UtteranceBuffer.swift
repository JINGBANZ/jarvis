import Foundation

/// Accumulates the `…transcription.completed` fragments of one spoken turn so the coach sees the
/// WHOLE utterance, not just the first fragment. The shared transcription coordinator briefly waits
/// to batch nearby fragments and drains this buffer only after the provider reports no unfinished
/// work. Pure and lock-guarded so the batching is unit-testable outside the app target.
public final class UtteranceBuffer: @unchecked Sendable {
    public enum DrainResult: Equatable, Sendable {
        case empty
        case waitingForPendingTranscriptions
        case ready(text: String, fragments: Int)
    }

    private let lock = NSLock()
    private var text = ""
    private var fragments = 0
    /// A batching delay expired while the provider still owned unfinished work. The lifecycle,
    /// rather than a polling timer, uses this bit to schedule a fresh batch once that work is terminal.
    private var waitingForPendingTranscriptions = false

    public init() {}

    /// Append a non-empty fragment, space-joined onto what's pending.
    public func append(_ fragment: String) {
        guard !fragment.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        text += (text.isEmpty ? "" : " ") + fragment
        fragments += 1
        // This new final fragment starts a fresh batching delay. If another item is still active,
        // expiry will put the buffer back into the waiting state.
        waitingForPendingTranscriptions = false
    }

    /// Drain only after every provider item for this speaker is terminal. A later fragment can already
    /// be active when the previous fragment's final transcript arrives, so an elapsed batching delay
    /// alone is not evidence that the semantic turn ended.
    public func drainIfSettled(hasPendingTranscriptions: Bool) -> DrainResult {
        lock.lock(); defer { lock.unlock() }
        guard fragments > 0 else {
            waitingForPendingTranscriptions = false
            return .empty
        }
        guard !hasPendingTranscriptions else {
            waitingForPendingTranscriptions = true
            return .waitingForPendingTranscriptions
        }
        let result = DrainResult.ready(text: text, fragments: fragments)
        text = ""; fragments = 0; waitingForPendingTranscriptions = false
        return result
    }

    /// Returns true exactly once when a delayed batch has become eligible for a fresh wait. This also
    /// wakes a buffered turn when the last pending item resolves without text.
    public func shouldResumeAfterPendingTranscriptionsSettle(
        hasPendingTranscriptions: Bool
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard waitingForPendingTranscriptions, !hasPendingTranscriptions, fragments > 0 else {
            return false
        }
        waitingForPendingTranscriptions = false
        return true
    }

    /// Return the coalesced utterance and fragment count, and reset.
    public func flush() -> (text: String, fragments: Int) {
        lock.lock(); defer { lock.unlock() }
        let result = (text, fragments)
        text = ""; fragments = 0; waitingForPendingTranscriptions = false
        return result
    }

    public func clear() {
        lock.lock()
        text = ""; fragments = 0; waitingForPendingTranscriptions = false
        lock.unlock()
    }
}
