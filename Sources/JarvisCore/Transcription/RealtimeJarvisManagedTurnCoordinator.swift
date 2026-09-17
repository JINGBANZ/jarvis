import Foundation

public struct RealtimeJarvisManagedTurnCoordinator: Sendable {
    public struct Turn: Equatable, Sendable {
        public let id: UInt64
        public let startedAt: TimeInterval
        public let committedThroughAt: TimeInterval
        public let throughSequenceNumber: UInt64
        /// False once bound to a server `item_id`, so a replayed turn can't consume the
        /// capture-side pending marker twice.
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
    /// Covers a provider delivering completion before the commit acknowledgement.
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

    /// Returns a boundary only once every append through it has completed locally. It joins the
    /// acknowledgement queue before the async send, so a fast acknowledgement is safe.
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

    /// A commit must stay ahead of the next turn's audio on the ordered WebSocket.
    public func allowsSendingAudio(sequenceNumber: UInt64) -> Bool {
        guard commitSendInFlightID == nil else { return false }
        guard let boundary = pendingTurns.first?.throughSequenceNumber else { return true }
        return sequenceNumber <= boundary
    }

    public mutating func recordCommitSendCompleted(turnID: UInt64) {
        if commitSendInFlightID == turnID { commitSendInFlightID = nil }
    }

    /// Retains the turn until its item is terminal, so a socket loss can replay committed but
    /// unfinished audio.
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

    /// Call after the audio FIFO has prepared its replay tail. Returns the boundaries older than
    /// the retained audio, which are unrecoverable.
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

    /// Otherwise a later append could be committed as the missing turn.
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
