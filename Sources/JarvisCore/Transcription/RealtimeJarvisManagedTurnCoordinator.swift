import Foundation

/// Orders explicit Realtime commits for turns Jarvis manages with local speech detection.
/// Keeps those boundaries aligned with the audio FIFO and replayable across reconnects.
/// The socket owner serializes access to this value alongside its connection state.
public struct RealtimeJarvisManagedTurnCoordinator: Sendable {
    public struct Turn: Equatable, Sendable {
        public let id: UInt64
        public let startedAt: TimeInterval
        public let committedThroughAt: TimeInterval
        public let throughSequenceNumber: UInt64
        /// True until this logical turn is first associated with a server `item_id`. A replayed turn
        /// has already consumed the capture-side pending marker and must not consume it twice.
        public let needsInitialItemBinding: Bool

        fileprivate func markingItemBound() -> Turn {
            Turn(id: id, startedAt: startedAt, committedThroughAt: committedThroughAt,
                 throughSequenceNumber: throughSequenceNumber,
                 needsInitialItemBinding: false)
        }
    }

    private struct AcknowledgedTurn: Sendable {
        let itemID: String
        let turn: Turn
    }

    private var nextTurnID: UInt64 = 1
    private var lastSentSequenceNumber: UInt64?
    private var commitSendInFlightID: UInt64?
    private var pendingTurns: [Turn] = []
    private var awaitingAcknowledgement: [Turn] = []
    private var acknowledgedTurns: [AcknowledgedTurn] = []
    /// Server events share one ordered socket in normal operation, but retaining an early terminal ID
    /// makes the coordinator safe even if a provider delivers completion before the commit acknowledgement.
    private var itemsFinishedBeforeAcknowledgement: Set<String> = []

    public init() {}

    public mutating func recordTurn(
        startedAt: TimeInterval,
        committedThroughAt: TimeInterval,
        throughSequenceNumber: UInt64
    ) {
        guard startedAt.isFinite, committedThroughAt.isFinite,
              committedThroughAt >= startedAt else { return }
        pendingTurns.append(Turn(
            id: nextTurnID,
            startedAt: startedAt,
            committedThroughAt: committedThroughAt,
            throughSequenceNumber: throughSequenceNumber,
            needsInitialItemBinding: true))
        nextTurnID &+= 1
    }

    public mutating func recordAudioSent(sequenceNumber: UInt64) {
        lastSentSequenceNumber = max(lastSentSequenceNumber ?? sequenceNumber, sequenceNumber)
    }

    /// Returns the next boundary only after every append through it has completed locally. Moving the
    /// turn into the acknowledgement queue before the async send also makes an unusually fast server
    /// acknowledgement safe.
    public mutating func takeReadyCommit() -> Turn? {
        guard commitSendInFlightID == nil,
              let sentThrough = lastSentSequenceNumber,
              let first = pendingTurns.first,
              first.throughSequenceNumber <= sentThrough else { return nil }
        pendingTurns.removeFirst()
        awaitingAcknowledgement.append(first)
        commitSendInFlightID = first.id
        return first
    }

    /// A commit must remain ahead of audio belonging to the next turn on the ordered WebSocket.
    public func allowsSendingAudio(sequenceNumber: UInt64) -> Bool {
        guard commitSendInFlightID == nil else { return false }
        guard let boundary = pendingTurns.first?.throughSequenceNumber else { return true }
        return sequenceNumber <= boundary
    }

    public mutating func recordCommitSendCompleted(turnID: UInt64) {
        if commitSendInFlightID == turnID { commitSendInFlightID = nil }
    }

    /// Match the server's ordered commit acknowledgement to the local boundary and retain it until
    /// the transcription item becomes terminal. That lets a socket loss replay committed-but-unfinished
    /// audio instead of losing a spoken turn.
    public mutating func acknowledgeCommittedItem(itemID: String) -> Turn? {
        guard !itemID.isEmpty, !awaitingAcknowledgement.isEmpty else { return nil }
        let turn = awaitingAcknowledgement.removeFirst()
        if commitSendInFlightID == turn.id { commitSendInFlightID = nil }
        if itemsFinishedBeforeAcknowledgement.remove(itemID) == nil {
            acknowledgedTurns.append(.init(itemID: itemID, turn: turn.markingItemBound()))
        }
        return turn
    }

    public mutating func recordItemFinished(itemID: String) {
        let previousCount = acknowledgedTurns.count
        acknowledgedTurns.removeAll { $0.itemID == itemID }
        if acknowledgedTurns.count == previousCount, !itemID.isEmpty,
           !awaitingAcknowledgement.isEmpty {
            itemsFinishedBeforeAcknowledgement.insert(itemID)
        }
    }

    /// Requeue every unresolved boundary after the audio FIFO has prepared its matching replay tail.
    /// Boundaries entirely older than the retained audio are returned to the caller as unrecoverable.
    @discardableResult
    public mutating func prepareForReconnect(
        oldestAvailableSequenceNumber: UInt64?
    ) -> [Turn] {
        pendingTurns = (acknowledgedTurns.map(\.turn) + awaitingAcknowledgement + pendingTurns)
            .sorted {
                if $0.throughSequenceNumber == $1.throughSequenceNumber { return $0.id < $1.id }
                return $0.throughSequenceNumber < $1.throughSequenceNumber
            }
        acknowledgedTurns.removeAll(keepingCapacity: true)
        awaitingAcknowledgement.removeAll(keepingCapacity: true)
        itemsFinishedBeforeAcknowledgement.removeAll(keepingCapacity: true)
        commitSendInFlightID = nil
        lastSentSequenceNumber = nil
        guard let oldestAvailableSequenceNumber else {
            let dropped = pendingTurns
            pendingTurns.removeAll(keepingCapacity: true)
            return dropped
        }
        return discardPendingTurns(before: oldestAvailableSequenceNumber)
    }

    /// Drop boundaries whose final audio chunk is absent, preventing a later append from accidentally
    /// being committed as the missing turn.
    @discardableResult
    public mutating func discardPendingTurns(before sequenceNumber: UInt64) -> [Turn] {
        var dropped: [Turn] = []
        while let first = pendingTurns.first,
              first.throughSequenceNumber < sequenceNumber {
            dropped.append(pendingTurns.removeFirst())
        }
        return dropped
    }

    public var unresolvedTurnCount: Int {
        pendingTurns.count + awaitingAcknowledgement.count + acknowledgedTurns.count
    }

    public mutating func clear() {
        nextTurnID = 1
        lastSentSequenceNumber = nil
        commitSendInFlightID = nil
        pendingTurns.removeAll(keepingCapacity: false)
        awaitingAcknowledgement.removeAll(keepingCapacity: false)
        acknowledgedTurns.removeAll(keepingCapacity: false)
        itemsFinishedBeforeAcknowledgement.removeAll(keepingCapacity: false)
    }
}
