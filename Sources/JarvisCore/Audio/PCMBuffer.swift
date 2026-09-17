import Foundation

/// Realtime never acknowledges `input_audio_buffer.append`, so sent chunks stay in a recovery tail
/// until server audio progress covers them. Both stores share `maxBytes`. Raw PCM never leaves
/// memory.
/// `@unchecked Sendable`: `lock` guards all mutable state.
public final class PCMBuffer: @unchecked Sendable {
    public struct Chunk: Equatable, Sendable {
        public let data: Data
        public let sequenceNumber: UInt64?
        /// Session-relative. Nil skips timeline reconciliation.
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

    /// The chunk stays queued until `completeSend(_:)`. A stale callback can release only its own
    /// claim, never a newer one.
    public struct Claim: Equatable, Sendable {
        fileprivate let id: UInt64
        public let chunk: Chunk
    }

    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var sentChunks: [Chunk] = []
    private var queuedByteCount = 0
    private var sentByteCount = 0
    private var activeClaim: Claim?
    private var nextClaimID: UInt64 = 1
    /// Kept because a server event can arrive before URLSession's local send callback; it is
    /// applied when that callback lands.
    private var serverConfirmedThrough: TimeInterval?
    private let maxBytes: Int

    public init(maxBytes: Int) { self.maxBytes = max(0, maxBytes) }

    /// Always keeps the newest chunk. Returns every evicted chunk; any eviction is a real loss of
    /// replay coverage.
    @discardableResult
    public func append(_ data: Data, sequenceNumber: UInt64? = nil,
                       capturedAt: TimeInterval? = nil, duration: TimeInterval = 0) -> [Chunk] {
        guard !data.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        chunks.append(Chunk(data: data, sequenceNumber: sequenceNumber,
                            capturedAt: capturedAt, duration: duration))
        queuedByteCount += data.count
        // Evict already-sent audio first; the newest capture matters most in a long outage.
        var evicted: [Chunk] = []
        trimSentTailLocked(recordingIn: &evicted)
        // Never evict the chunk URLSession may be sending, so the FIFO can exceed `maxBytes` by
        // that one chunk.
        let claimedBytes = activeClaim?.chunk.data.count ?? 0
        while queuedByteCount - claimedBytes > maxBytes, chunks.count > 1 {
            let index = activeClaim == nil ? 0 : 1
            let removed = chunks.remove(at: index)
            queuedByteCount -= removed.data.count
            evicted.append(removed)
        }
        return evicted
    }

    /// Nil while another claim is active, so no later chunk can be sent ahead of it.
    public func claimNext() -> Claim? {
        lock.lock(); defer { lock.unlock() }
        guard activeClaim == nil, let chunk = chunks.first else { return nil }
        let claim = Claim(id: nextClaimID, chunk: chunk)
        nextClaimID &+= 1
        activeClaim = claim
        return claim
    }

    public struct SendCompletion: Equatable, Sendable {
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

    @discardableResult
    public func retry(_ claim: Claim) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard activeClaim?.id == claim.id else { return false }
        activeClaim = nil
        return true
    }

    public func retryInFlight() {
        lock.lock(); activeClaim = nil; lock.unlock()
    }

    public struct ReplayPreparation: Equatable, Sendable {
        public let replayedChunks: Int
        public let oldestCapturedAt: TimeInterval?
        public let oldestSequenceNumber: UInt64?
        public let evicted: [Chunk]
    }

    /// The sent tail goes back ahead of never-sent chunks, preserving order. Invalidates the active
    /// claim, so a stale callback can't remove a replayed chunk.
    @discardableResult
    public func prepareForReconnect() -> ReplayPreparation {
        lock.lock(); defer { lock.unlock() }
        // A socket failure can beat the send callback of a server-confirmed claim, so drop the
        // confirmed prefix. Untimed chunks stay replayable.
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

    public func drain() -> [Data] {
        drainChunks().map(\.data)
    }

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

    /// Unlike `nextQueuedSequenceNumber`, includes the sent recovery tail.
    public var oldestRetainedSequenceNumber: UInt64? {
        lock.lock(); defer { lock.unlock() }
        let oldestSent = sentChunks.first { $0.sequenceNumber != nil }?.sequenceNumber
        let oldestQueued = chunks.first { $0.sequenceNumber != nil }?.sequenceNumber
        return oldestSent ?? oldestQueued
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
