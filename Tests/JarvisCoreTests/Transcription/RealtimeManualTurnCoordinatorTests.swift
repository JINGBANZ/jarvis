import Foundation
import Testing
@testable import JarvisCore

@Suite struct RealtimeManualTurnCoordinatorTests {
    @Test func commitWaitsUntilAudioThroughBoundaryWasSent() throws {
        var coordinator = RealtimeManualTurnCoordinator()
        coordinator.recordTurn(startedAt: 1, committedThroughAt: 2, throughSequenceNumber: 4)

        coordinator.recordAudioSent(sequenceNumber: 3)
        #expect(coordinator.takeReadyCommit() == nil)
        #expect(coordinator.allowsSendingAudio(sequenceNumber: 4))
        #expect(!coordinator.allowsSendingAudio(sequenceNumber: 5))

        coordinator.recordAudioSent(sequenceNumber: 4)
        let readyTurn = coordinator.takeReadyCommit()
        let turn = try #require(readyTurn)
        #expect(turn.throughSequenceNumber == 4)
        #expect(!coordinator.allowsSendingAudio(sequenceNumber: 5))

        coordinator.recordCommitSendCompleted(turnID: turn.id)
        #expect(coordinator.allowsSendingAudio(sequenceNumber: 5))
    }

    @Test func acknowledgementBindsTurnOnlyOnceAcrossReplay() throws {
        var coordinator = RealtimeManualTurnCoordinator()
        coordinator.recordTurn(startedAt: 1, committedThroughAt: 2, throughSequenceNumber: 4)
        coordinator.recordAudioSent(sequenceNumber: 4)
        let readyFirstCommit = coordinator.takeReadyCommit()
        let firstCommit = try #require(readyFirstCommit)
        coordinator.recordCommitSendCompleted(turnID: firstCommit.id)
        let acknowledgedFirst = coordinator.acknowledgeCommittedItem(itemID: "old-item")
        let firstBinding = try #require(acknowledgedFirst)
        #expect(firstBinding.needsInitialItemBinding)

        #expect(coordinator.prepareForReconnect(oldestAvailableSequenceNumber: 1).isEmpty)
        coordinator.recordAudioSent(sequenceNumber: 4)
        let readyReplayCommit = coordinator.takeReadyCommit()
        let replayCommit = try #require(readyReplayCommit)
        coordinator.recordCommitSendCompleted(turnID: replayCommit.id)
        let acknowledgedReplay = coordinator.acknowledgeCommittedItem(itemID: "replacement-item")
        let replayBinding = try #require(acknowledgedReplay)
        #expect(!replayBinding.needsInitialItemBinding)
    }

    @Test func sentBoundaryRemainsCommitEligibleWhenNextChunkIsQueued() throws {
        let buffer = PCMBuffer(maxBytes: 1_000)
        buffer.append(Data([4]), sequenceNumber: 4, capturedAt: 4, duration: 1)
        buffer.append(Data([5]), sequenceNumber: 5, capturedAt: 5, duration: 1)
        var coordinator = RealtimeManualTurnCoordinator()
        coordinator.recordTurn(startedAt: 3, committedThroughAt: 5, throughSequenceNumber: 4)

        let boundaryClaim = try #require(buffer.claimNext())
        #expect(buffer.completeSend(boundaryClaim) != nil)
        coordinator.recordAudioSent(sequenceNumber: 4)

        #expect(buffer.nextQueuedSequenceNumber == 5)
        let retainedSequence = try #require(buffer.oldestRetainedSequenceNumber)
        #expect(retainedSequence == 4)
        #expect(coordinator.discardPendingTurns(before: retainedSequence).isEmpty)
        let readyCommit = coordinator.takeReadyCommit()
        #expect(try #require(readyCommit).throughSequenceNumber == 4)
    }

    @Test func terminalItemIsNotReplayed() throws {
        var coordinator = RealtimeManualTurnCoordinator()
        coordinator.recordTurn(startedAt: 1, committedThroughAt: 2, throughSequenceNumber: 4)
        coordinator.recordAudioSent(sequenceNumber: 4)
        let readyCommit = coordinator.takeReadyCommit()
        let commit = try #require(readyCommit)
        coordinator.recordCommitSendCompleted(turnID: commit.id)
        _ = coordinator.acknowledgeCommittedItem(itemID: "item")
        coordinator.recordItemFinished(itemID: "item")

        #expect(coordinator.prepareForReconnect(oldestAvailableSequenceNumber: 1).isEmpty)
        #expect(coordinator.unresolvedTurnCount == 0)
    }

    @Test func terminalBeforeAcknowledgementIsNotReplayed() throws {
        var coordinator = RealtimeManualTurnCoordinator()
        coordinator.recordTurn(startedAt: 1, committedThroughAt: 2, throughSequenceNumber: 8)
        coordinator.recordAudioSent(sequenceNumber: 8)
        let readyCommit = coordinator.takeReadyCommit()
        _ = try #require(readyCommit)

        coordinator.recordItemFinished(itemID: "item-early")
        let acknowledged = coordinator.acknowledgeCommittedItem(itemID: "item-early")
        #expect(try #require(acknowledged).needsInitialItemBinding)
        #expect(coordinator.unresolvedTurnCount == 0)

        #expect(coordinator.prepareForReconnect(oldestAvailableSequenceNumber: 1).isEmpty)
        #expect(coordinator.takeReadyCommit() == nil)
    }

    @Test func missingReplayAudioDropsBoundaryInsteadOfCommittingNewerAudio() throws {
        var coordinator = RealtimeManualTurnCoordinator()
        coordinator.recordTurn(startedAt: 1, committedThroughAt: 2, throughSequenceNumber: 4)
        coordinator.recordTurn(startedAt: 3, committedThroughAt: 4, throughSequenceNumber: 9)

        let dropped = coordinator.discardPendingTurns(before: 7)
        #expect(dropped.map(\.throughSequenceNumber) == [4])
        #expect(dropped.allSatisfy { $0.needsInitialItemBinding })
        #expect(coordinator.allowsSendingAudio(sequenceNumber: 7))
        coordinator.recordAudioSent(sequenceNumber: 9)
        let readyCommit = coordinator.takeReadyCommit()
        #expect(try #require(readyCommit).throughSequenceNumber == 9)
    }
}
