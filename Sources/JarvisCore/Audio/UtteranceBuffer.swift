import Foundation

/// `@unchecked Sendable`: `lock` guards all mutable state.
public final class UtteranceBuffer: @unchecked Sendable {
    public enum DrainResult: Equatable, Sendable {
        case empty
        case waitingForPendingTranscriptions
        case ready(text: String, fragments: Int)
    }

    private let lock = NSLock()
    private var text = ""
    private var fragments = 0
    /// Set when a batch delay expires during pending work, so settlement reschedules it, not
    /// polling.
    private var waitingForPendingTranscriptions = false

    public init() {}

    public func append(_ fragment: String) {
        guard !fragment.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        text += (text.isEmpty ? "" : " ") + fragment
        fragments += 1
        // A new fragment starts a fresh batching delay.
        waitingForPendingTranscriptions = false
    }

    /// An elapsed batching delay alone doesn't end a turn: a later fragment may already be in
    /// flight.
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

    /// True once per delayed batch, including when the last pending item resolves without text.
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
