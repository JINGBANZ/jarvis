import Foundation

/// A byte-capped FIFO of PCM audio chunks plus an in-memory recovery tail.
///
/// A successful WebSocket send callback proves only that the local transport accepted a message;
/// Realtime deliberately sends no acknowledgement for `input_audio_buffer.append`. Locally-sent
/// chunks therefore remain in `sentChunks` until a server audio-clock event proves that prefix is no
/// longer needed. On reconnect, the unconfirmed tail moves back ahead of audio that was never sent.
///
/// Both stores are bounded by `maxBytes`, raw PCM never leaves memory, and every mutation is
/// lock-guarded so the recovery contract is unit-testable outside the app target.
public final class PCMBuffer: @unchecked Sendable {
    public struct Chunk: Equatable, Sendable {
        public let data: Data
        public let sequenceNumber: UInt64?
        /// Session-relative capture time. Nil is supported for callers that do not need timeline
        /// reconciliation (principally small unit-test fixtures).
        public let capturedAt: TimeInterval?
        public let duration: TimeInterval

        public init(data: Data, sequenceNumber: UInt64? = nil,
                    capturedAt: TimeInterval? = nil, duration: TimeInterval = 0) {
            precondition(duration >= 0)
            self.data = data
            self.sequenceNumber = sequenceNumber
            self.capturedAt = capturedAt
            self.duration = duration
        }

        fileprivate var capturedEnd: TimeInterval? { capturedAt.map { $0 + duration } }
    }

    /// One exclusive send claim. The chunk remains in the pending FIFO until `completeSend(_:)`;
    /// a failed/stale transport callback can only release its own claim, never remove a newer one.
    public struct Claim: Equatable, Sendable {
        fileprivate let id: UInt64
        public let chunk: Chunk
    }

    private let lock = NSLock()
    private var chunks: [Chunk] = []
    /// Chunks accepted by the local WebSocket stack but not yet covered by server audio progress.
    private var sentChunks: [Chunk] = []
    private var queuedByteCount = 0
    private var sentByteCount = 0
    private var activeClaim: Claim?
    private var nextClaimID: UInt64 = 1
    /// Highest session-relative capture boundary proven by a server lifecycle event. A server event
    /// can race ahead of URLSession's local send callback, so the boundary must outlive the immediate
    /// `sentChunks` scan and be applied when that callback eventually arrives.
    private var serverConfirmedThrough: TimeInterval?
    private let maxBytes: Int

    public init(maxBytes: Int) { self.maxBytes = max(0, maxBytes) }

    /// Append a chunk, evicting the oldest chunks if the cap is exceeded. The most recently appended
    /// chunk is always retained (an in-progress utterance matters more than stale audio). The return
    /// value contains every evicted chunk. A local WebSocket send completion is not a server
    /// acknowledgement, so expiry from either the pending queue or recovery tail is a real,
    /// diagnostic-worthy loss of replay coverage.
    @discardableResult
    public func append(_ data: Data, sequenceNumber: UInt64? = nil,
                       capturedAt: TimeInterval? = nil, duration: TimeInterval = 0) -> [Chunk] {
        guard !data.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        chunks.append(Chunk(data: data, sequenceNumber: sequenceNumber,
                            capturedAt: capturedAt, duration: duration))
        queuedByteCount += data.count
        // The recovery tail and never-sent queue share one memory budget. Retire the oldest local
        // send first; the newest captured audio is more valuable during a prolonged outage.
        var evicted: [Chunk] = []
        trimSentTailLocked(recordingIn: &evicted)
        // Never evict the chunk URLSession may currently be sending. While it is claimed, apply the
        // cap to the waiting tail; the FIFO can exceed `maxBytes` by at most that one in-flight chunk.
        let claimedBytes = activeClaim?.chunk.data.count ?? 0
        while queuedByteCount - claimedBytes > maxBytes, chunks.count > 1 {
            let index = activeClaim == nil ? 0 : 1
            let removed = chunks.remove(at: index)
            queuedByteCount -= removed.data.count
            evicted.append(removed)
        }
        return evicted
    }

    /// Exclusively claims the oldest chunk without removing it. A second producer/ready transition
    /// sees the active claim and cannot send a later chunk ahead of it.
    public func claimNext() -> Claim? {
        lock.lock(); defer { lock.unlock() }
        guard activeClaim == nil, let chunk = chunks.first else { return nil }
        let claim = Claim(id: nextClaimID, chunk: chunk)
        nextClaimID &+= 1
        activeClaim = claim
        return claim
    }

    /// Moves a chunk into the recovery tail after the exact asynchronous *local* send succeeds.
    /// This is intentionally not called an acknowledgement: the Realtime server does not confirm
    /// append events, so the chunk must remain replayable until `discardSent(through:)` advances it.
    public struct SendCompletion: Equatable, Sendable {
        /// Unconfirmed recovery-tail chunks dropped to preserve the shared byte cap.
        public let evicted: [Chunk]
    }

    @discardableResult
    public func completeSend(_ claim: Claim) -> SendCompletion? {
        lock.lock(); defer { lock.unlock() }
        guard activeClaim?.id == claim.id, chunks.first == claim.chunk else { return nil }
        let sent = chunks.removeFirst()
        queuedByteCount -= sent.data.count
        if !isServerConfirmedLocked(sent) {
            sentChunks.append(sent)
            sentByteCount += sent.data.count
        }
        activeClaim = nil
        var evicted: [Chunk] = []
        trimSentTailLocked(recordingIn: &evicted)
        return SendCompletion(evicted: evicted)
    }

    /// Makes the exact failed claim available for ordered retry. Stale callbacks are harmless.
    @discardableResult
    public func retry(_ claim: Claim) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard activeClaim?.id == claim.id else { return false }
        activeClaim = nil
        return true
    }

    /// Releases whichever send was active when the current socket failed. The chunk stays first.
    public func retryInFlight() {
        lock.lock(); activeClaim = nil; lock.unlock()
    }

    public struct ReplayPreparation: Equatable, Sendable {
        public let replayedChunks: Int
        public let oldestCapturedAt: TimeInterval?
        public let oldestSequenceNumber: UInt64?
        public let evicted: [Chunk]
    }

    /// Requeues everything that was accepted only by the local transport. TCP preserves order, so
    /// this tail belongs before chunks captured after the connection became visibly unavailable.
    /// A stale callback's claim is invalidated and cannot remove a replayed chunk later.
    @discardableResult
    public func prepareForReconnect() -> ReplayPreparation {
        lock.lock(); defer { lock.unlock() }
        // A socket failure can win before the local callback for a server-confirmed active claim.
        // Drop only the proven prefix before rebuilding the replay FIFO; unknown-timestamp chunks
        // stay conservative and replayable.
        trimServerConfirmedQueuedPrefixLocked()
        let replayed = sentChunks.count
        chunks = sentChunks + chunks
        queuedByteCount += sentByteCount
        sentChunks.removeAll(keepingCapacity: true)
        sentByteCount = 0
        activeClaim = nil

        var evicted: [Chunk] = []
        while queuedByteCount > maxBytes, chunks.count > 1 {
            let removed = chunks.removeFirst()
            queuedByteCount -= removed.data.count
            evicted.append(removed)
        }
        return ReplayPreparation(replayedChunks: replayed,
                                 oldestCapturedAt: chunks.first?.capturedAt,
                                 oldestSequenceNumber: chunks.first?.sequenceNumber,
                                 evicted: evicted)
    }

    /// Discards the locally-sent prefix whose capture timeline is covered by a server VAD /
    /// transcription lifecycle boundary. Pending chunks are never affected.
    @discardableResult
    public func discardSent(through capturedTime: TimeInterval) -> [Chunk] {
        lock.lock(); defer { lock.unlock() }
        serverConfirmedThrough = max(serverConfirmedThrough ?? capturedTime, capturedTime)
        var discarded: [Chunk] = []
        while let first = sentChunks.first,
              let end = first.capturedEnd, end <= capturedTime {
            let removed = sentChunks.removeFirst()
            sentByteCount -= removed.data.count
            discarded.append(removed)
        }
        if activeClaim == nil {
            trimServerConfirmedQueuedPrefixLocked()
        }
        return discarded
    }

    /// Remove and return all buffered chunks in arrival order.
    public func drain() -> [Data] {
        drainChunks().map(\.data)
    }

    /// Sequenced drain used by Realtime reconnect replay so the continuity witness can prove which
    /// captured chunks were attempted on the replacement socket.
    public func drainChunks() -> [Chunk] {
        lock.lock(); defer { lock.unlock() }
        let out = sentChunks + chunks
        chunks = []; sentChunks = []
        queuedByteCount = 0; sentByteCount = 0; activeClaim = nil
        return out
    }

    public func clear() {
        lock.lock()
        chunks = []; sentChunks = []
        queuedByteCount = 0; sentByteCount = 0; activeClaim = nil
        serverConfirmedThrough = nil
        lock.unlock()
    }

    public var bufferedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return queuedByteCount + sentByteCount
    }

    public var bufferedChunkCount: Int {
        lock.lock(); defer { lock.unlock() }
        return chunks.count + sentChunks.count
    }

    public var queuedChunkCount: Int {
        lock.lock(); defer { lock.unlock() }
        return chunks.count
    }

    public var oldestQueuedCaptureTime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return chunks.first?.capturedAt
    }

    public var nextQueuedSequenceNumber: UInt64? {
        lock.lock(); defer { lock.unlock() }
        return chunks.first?.sequenceNumber
    }

    private func trimSentTailLocked(recordingIn evicted: inout [Chunk]) {
        while sentByteCount + queuedByteCount > maxBytes, !sentChunks.isEmpty,
              sentChunks.count > 1 || !chunks.isEmpty {
            let removed = sentChunks.removeFirst()
            sentByteCount -= removed.data.count
            evicted.append(removed)
        }
    }

    private func isServerConfirmedLocked(_ chunk: Chunk) -> Bool {
        guard let boundary = serverConfirmedThrough, let end = chunk.capturedEnd else { return false }
        return end <= boundary
    }

    private func trimServerConfirmedQueuedPrefixLocked() {
        while let first = chunks.first, isServerConfirmedLocked(first) {
            queuedByteCount -= chunks.removeFirst().data.count
        }
        activeClaim = nil
    }
}
