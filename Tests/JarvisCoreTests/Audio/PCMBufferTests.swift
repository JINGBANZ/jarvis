import Foundation
import Testing
@testable import JarvisCore

@Suite struct PCMBufferTests {
    @Test func appendsAndDrainsInOrder() {
        let b = PCMBuffer(maxBytes: 1000)
        b.append(Data([1, 2, 3]))
        b.append(Data([4, 5]))
        #expect(b.bufferedBytes == 5)
        let chunks = b.drain()
        #expect(chunks == [Data([1, 2, 3]), Data([4, 5])])
        #expect(b.bufferedBytes == 0)   // drain clears
    }

    /// Beyond the cap, the OLDEST audio is evicted (a long outage keeps only the most recent window).
    @Test func evictsOldestBeyondCap() {
        let b = PCMBuffer(maxBytes: 5)
        b.append(Data([1, 2, 3]))      // 3 bytes
        b.append(Data([4, 5, 6]))      // would be 6 > 5 → drop the first chunk
        #expect(b.bufferedBytes <= 5)
        #expect(b.drain() == [Data([4, 5, 6])])
    }

    /// The most recent chunk is always retained, even if it alone exceeds the cap.
    @Test func keepsNewestEvenIfLargerThanCap() {
        let b = PCMBuffer(maxBytes: 2)
        b.append(Data([1, 2, 3, 4]))
        #expect(b.drain() == [Data([1, 2, 3, 4])])
    }

    @Test func clearEmpties() {
        let b = PCMBuffer(maxBytes: 100)
        b.append(Data([9]))
        b.clear()
        #expect(b.bufferedBytes == 0)
        #expect(b.drain().isEmpty)
    }

    @Test func sequencedChunksSurviveReconnectBuffering() {
        let b = PCMBuffer(maxBytes: 100)
        b.append(Data([1, 2]), sequenceNumber: 41)
        b.append(Data([3, 4]), sequenceNumber: 42)

        #expect(b.drainChunks() == [
            .init(data: Data([1, 2]), sequenceNumber: 41),
            .init(data: Data([3, 4]), sequenceNumber: 42),
        ])
    }

    @Test func claimedChunkRemainsFirstUntilLocalSendCompletes() throws {
        let b = PCMBuffer(maxBytes: 100)
        b.append(Data([1]), sequenceNumber: 1)
        b.append(Data([2]), sequenceNumber: 2)

        let first = try #require(b.claimNext())
        #expect(first.chunk.sequenceNumber == 1)
        #expect(b.claimNext() == nil)
        #expect(b.completeSend(first))

        let second = try #require(b.claimNext())
        #expect(second.chunk.sequenceNumber == 2)
    }

    @Test func failedSendRetriesExactChunkBeforeLaterAudio() throws {
        let b = PCMBuffer(maxBytes: 100)
        b.append(Data([1]), sequenceNumber: 41)
        let failed = try #require(b.claimNext())
        b.append(Data([2]), sequenceNumber: 42)

        #expect(b.retry(failed))
        let retry = try #require(b.claimNext())
        #expect(retry.chunk.sequenceNumber == 41)
        #expect(retry != failed) // a stale callback cannot complete the replacement claim
        #expect(!b.completeSend(failed))
        #expect(b.completeSend(retry))
        #expect(b.claimNext()?.chunk.sequenceNumber == 42)
    }

    @Test func appendAfterEmptyReadyBoundaryCannotBeStranded() throws {
        let b = PCMBuffer(maxBytes: 100)

        #expect(b.claimNext() == nil) // readiness found the queue empty
        b.append(Data([9]), sequenceNumber: 9) // producer races immediately after that check

        let claim = try #require(b.claimNext())
        #expect(claim.chunk.sequenceNumber == 9)
    }

    @Test func capNeverEvictsInFlightChunk() throws {
        let b = PCMBuffer(maxBytes: 3)
        b.append(Data([1, 1, 1]), sequenceNumber: 1)
        let inFlight = try #require(b.claimNext())
        let evicted = b.append(Data([2, 2, 2, 2]), sequenceNumber: 2)

        #expect(evicted.map(\.sequenceNumber) == [2])
        #expect(b.retry(inFlight))
        #expect(b.claimNext()?.chunk.sequenceNumber == 1)
    }

    /// URLSession can report a successful local send while a half-open socket has delivered no
    /// bytes to the server. The chunk therefore remains available to the replacement connection.
    @Test func localSendCompletionDoesNotRemoveChunkFromReconnectReplay() throws {
        let b = PCMBuffer(maxBytes: 100)
        b.append(Data([1, 2]), sequenceNumber: 41, capturedAt: 10, duration: 0.01)
        let locallySent = try #require(b.claimNext())
        #expect(b.completeSend(locallySent))
        #expect(b.claimNext() == nil)

        let recovery = b.prepareForReconnect()
        #expect(recovery.replayedChunks == 1)
        #expect(recovery.oldestCapturedAt == 10)
        #expect(try #require(b.claimNext()).chunk.sequenceNumber == 41)
    }

    @Test func reconnectReplaysLocalTailBeforeNeverSentAudio() throws {
        let b = PCMBuffer(maxBytes: 100)
        b.append(Data([1]), sequenceNumber: 1, capturedAt: 1, duration: 0.01)
        let sent = try #require(b.claimNext())
        #expect(b.completeSend(sent))
        b.append(Data([2]), sequenceNumber: 2, capturedAt: 2, duration: 0.01)

        b.prepareForReconnect()
        #expect(b.drainChunks().map(\.sequenceNumber) == [1, 2])
    }

    @Test func serverProgressDiscardsOnlyCoveredLocalSendPrefix() throws {
        let b = PCMBuffer(maxBytes: 100)
        for sequence in 1...3 {
            b.append(Data([UInt8(sequence)]), sequenceNumber: UInt64(sequence),
                     capturedAt: TimeInterval(sequence), duration: 0.5)
            let claim = try #require(b.claimNext())
            #expect(b.completeSend(claim))
        }

        #expect(b.discardSent(through: 2.5).map(\.sequenceNumber) == [1, 2])
        b.prepareForReconnect()
        #expect(b.drainChunks().map(\.sequenceNumber) == [3])
    }

    @Test func staleLocalCompletionCannotRemoveRequeuedChunk() throws {
        let b = PCMBuffer(maxBytes: 100)
        b.append(Data([1]), sequenceNumber: 1, capturedAt: 1, duration: 0.01)
        let oldClaim = try #require(b.claimNext())

        b.prepareForReconnect()
        let replacementClaim = try #require(b.claimNext())
        #expect(!b.completeSend(oldClaim))
        #expect(b.completeSend(replacementClaim))

        b.prepareForReconnect()
        #expect(b.claimNext()?.chunk.sequenceNumber == 1)
    }

    @Test func localRecoveryTailAndPendingAudioShareTheMemoryCap() throws {
        let b = PCMBuffer(maxBytes: 3)
        b.append(Data([1, 1]), sequenceNumber: 1, capturedAt: 1, duration: 0.01)
        let sent = try #require(b.claimNext())
        #expect(b.completeSend(sent))

        b.append(Data([2, 2]), sequenceNumber: 2, capturedAt: 2, duration: 0.01)
        #expect(b.bufferedBytes <= 3)
        b.prepareForReconnect()
        #expect(b.drainChunks().map(\.sequenceNumber) == [2])
    }

    /// A full rolling recovery tail is expected to age out its oldest, already-locally-sent chunk
    /// as fresh outage audio arrives. Only eviction of audio that has never reached a socket is an
    /// unrecoverable continuity gap worth recording in diagnostics.
    @Test func reportsOverflowOnlyAfterNeverSentAudioAgesOut() throws {
        let b = PCMBuffer(maxBytes: 2)
        for sequence in 1...2 {
            b.append(Data([UInt8(sequence)]), sequenceNumber: UInt64(sequence))
            let claim = try #require(b.claimNext())
            #expect(b.completeSend(claim))
        }
        b.prepareForReconnect()

        #expect(b.append(Data([3]), sequenceNumber: 3).isEmpty)
        #expect(b.append(Data([4]), sequenceNumber: 4).isEmpty)
        #expect(b.append(Data([5]), sequenceNumber: 5).map(\.sequenceNumber) == [3])
        #expect(b.drainChunks().map(\.sequenceNumber) == [4, 5])
    }
}
