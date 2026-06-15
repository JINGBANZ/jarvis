import Foundation

/// A byte-capped FIFO of PCM audio chunks. While the realtime socket is down, captured audio is
/// buffered here instead of being discarded, then flushed into the new session on reconnect — so a
/// mid-sentence drop doesn't lose the user's words. Bounded by `maxBytes` (the oldest audio is
/// evicted past the cap) so a long outage can't grow memory without limit. Lock-guarded and pure, so
/// the eviction policy is unit-testable outside the app target.
public final class PCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var byteCount = 0
    private let maxBytes: Int

    public init(maxBytes: Int) { self.maxBytes = max(0, maxBytes) }

    /// Append a chunk, evicting the oldest chunks if the cap is exceeded. The most recently appended
    /// chunk is always retained (an in-progress utterance matters more than stale audio).
    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        chunks.append(data)
        byteCount += data.count
        while byteCount > maxBytes, chunks.count > 1 {
            byteCount -= chunks.removeFirst().count
        }
    }

    /// Remove and return all buffered chunks in arrival order.
    public func drain() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        let out = chunks
        chunks = []; byteCount = 0
        return out
    }

    public func clear() {
        lock.lock(); chunks = []; byteCount = 0; lock.unlock()
    }

    public var bufferedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return byteCount
    }
}
