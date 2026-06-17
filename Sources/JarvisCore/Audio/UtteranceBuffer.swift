import Foundation

/// Accumulates the `…transcription.completed` fragments of one spoken turn so the coach sees the
/// WHOLE utterance, not just the first fragment. The transcriber debounces fragment arrival and then
/// `flush`es this buffer to drive a single trigger. Pure and lock-guarded so the coalescing is
/// unit-testable outside the app target.
public final class UtteranceBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var fragments = 0

    public init() {}

    /// Append a non-empty fragment, space-joined onto what's pending.
    public func append(_ fragment: String) {
        guard !fragment.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        text += (text.isEmpty ? "" : " ") + fragment
        fragments += 1
    }

    /// Return the coalesced utterance and fragment count, and reset.
    public func flush() -> (text: String, fragments: Int) {
        lock.lock(); defer { lock.unlock() }
        let result = (text, fragments)
        text = ""; fragments = 0
        return result
    }

    public func clear() {
        lock.lock(); text = ""; fragments = 0; lock.unlock()
    }
}
