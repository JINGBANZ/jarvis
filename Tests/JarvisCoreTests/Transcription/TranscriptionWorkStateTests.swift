import Foundation
import Testing
@testable import JarvisCore

@Suite struct TranscriptionWorkStateTests {
    @Test func laterSpeechDoesNotBlockEarlierFinalizedContext() {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "question", audioStartMilliseconds: 1_000, timelineOrigin: 0)
        ledger.recordSpeechStarted(itemID: "later", audioStartMilliseconds: 3_000, timelineOrigin: 0)
        _ = ledger.recordCompleted(itemID: "question", transcript: "What is the complexity?", speaker: .me)

        #expect(ledger.coachingWorkState.permitsCoaching(through: 1))
        #expect(!ledger.coachingWorkState.permitsCoaching(through: 3))
        #expect(!ledger.coachingWorkState.permitsCoaching(through: nil))
    }

    @Test func pendingStartInsideTheMarginStillBlocks() {
        let margin = TranscriptionWorkState.startTimeMargin
        let spokenAt: TimeInterval = 2
        #expect(!TranscriptionWorkState.pending(since: spokenAt + margin / 2)
            .permitsCoaching(through: spokenAt))
        #expect(TranscriptionWorkState.pending(since: spokenAt + margin * 2)
            .permitsCoaching(through: spokenAt))
    }

    @Test func outOfOrderCompletionPreservesEarlierPendingBarrier() {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "earlier", audioStartMilliseconds: 1_000, timelineOrigin: 10)
        ledger.recordSpeechStarted(itemID: "reply", audioStartMilliseconds: 3_000, timelineOrigin: 10)
        _ = ledger.recordCompleted(itemID: "reply", transcript: "Yes", speaker: .me)
        #expect(!ledger.coachingWorkState.permitsCoaching(through: 13))

        _ = ledger.recordCompleted(itemID: "earlier", transcript: "Is that linear?", speaker: .me)
        #expect(ledger.coachingWorkState.permitsCoaching(through: 13))
    }

    @Test func untimedPendingItemRemainsBlockingUntilResolved() {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "later", audioStartMilliseconds: 3_000, timelineOrigin: 0)
        ledger.recordDelta(itemID: "unknown", delta: "unfinished")
        #expect(!ledger.coachingWorkState.permitsCoaching(through: 1))
        _ = ledger.recordFailed(itemID: "unknown", speaker: .me)
        #expect(ledger.coachingWorkState.permitsCoaching(through: 1))
    }

    @Test func invalidOrUnknownPendingTimeCannotAuthorizeCoaching() {
        for time: TimeInterval? in [nil, -.infinity, .infinity, .nan, -1, 1, 2] {
            #expect(!TranscriptionWorkState.pending(since: time).permitsCoaching(through: 2))
        }
        #expect(TranscriptionWorkState.pending(since: 3).permitsCoaching(through: 2))
        #expect(TranscriptionWorkState.settled.permitsCoaching(through: nil))
    }

    @Test func clientCommitSpeechInProgressAdmitsOnlyAnEarlierLine() {
        let ledger = RealtimeTranscriptionLedger()
        let speaking = ledger.coachingWorkState.including(pendingSince: 4)

        #expect(speaking.permitsCoaching(through: 1))
        #expect(!speaking.permitsCoaching(through: 4))
        #expect(!speaking.permitsCoaching(through: 5))
        #expect(!speaking.permitsCoaching(through: nil))
    }

    @Test func clientCommitSpeechInProgressKeepsTheLedgersEarlierOrUnknownStart() {
        let ledger = RealtimeTranscriptionLedger()
        ledger.recordSpeechStarted(itemID: "committed", audioStartMilliseconds: 2_000, timelineOrigin: 0)
        ledger.recordSpeechStopped(itemID: "committed", audioEndMilliseconds: 3_000)
        #expect(ledger.coachingWorkState.including(pendingSince: 4) == .pending(since: 2))

        ledger.recordDelta(itemID: "untimed", delta: "unfinished")
        let unknown = ledger.coachingWorkState.including(pendingSince: 4)
        #expect(unknown == .pending(since: nil))
        #expect(!unknown.permitsCoaching(through: 1))
    }

    @Test func anInvalidSpeechStartIsUnknown() {
        for start: TimeInterval in [-1, .infinity, .nan] {
            #expect(TranscriptionWorkState.pending(since: 2).including(pendingSince: start)
                == .pending(since: nil))
        }
    }
}
