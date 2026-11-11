import Foundation
import Testing
@testable import JarvisCore

@Suite struct TranscriptionCoachingCoordinatorTests {
    @Test func finalizedFragmentsWaitForActivityToSettleAndCoalesce() async {
        let transcript = RollingTranscript()
        let clock = ManualClock(now: 110)
        let events = CoachingEvents()
        let coordinator = makeCoordinator(
            transcript: transcript,
            clock: clock,
            sessionStart: 100,
            transcriptBatchingWindow: 0,
            events: events)
        guard let pendingTurn = PendingTurnProbe(coordinator) else {
            Issue.record("Could not inspect the coordinator's pending utterance buffer")
            return
        }

        coordinator.start()
        coordinator.updateTranscriptionWork(.pending(since: nil))
        #expect(coordinator.recordFinalizedTranscript(
            "  first fragment  ", spokenAt: 1, spokenEndAt: 1, source: "test"))
        #expect(coordinator.recordFinalizedTranscript(
            "second fragment", spokenAt: 2, spokenEndAt: 2, source: "test"))

        #expect(await waitUntil {
            pendingTurn.observeAndRestoreWaitingState()
        })
        #expect(events.turnCount == 0)
        #expect(events.activity == [true])

        coordinator.updateTranscriptionWork(.settled)
        #expect(await waitUntil { events.turnCount == 1 })
        #expect(events.firstTurnBoundary == 2)
        #expect(events.activity == [true, false])
        #expect(transcript.renderFrom(index: 0).text
            == "[00:01-00:01] me: first fragment\n[00:02-00:02] me: second fragment")
        coordinator.stop()
    }

    @Test func rejectsEmptyFinalsAndStopCancelsPendingTurn() async {
        let transcript = RollingTranscript()
        let clock = ManualClock(now: 13)
        let events = CoachingEvents()
        let transcriptBatchingWindow: TimeInterval = 0.02
        let coordinator = makeCoordinator(
            transcript: transcript,
            clock: clock,
            sessionStart: 10,
            transcriptBatchingWindow: transcriptBatchingWindow,
            events: events)

        let accepted = await recordAndStopBeforeQueuedBatchRuns(coordinator)
        #expect(!accepted.empty)
        #expect(accepted.usable)

        await waitForMainQueue(after: transcriptBatchingWindow * 2)
        #expect(events.turnCount == 0)
        #expect(events.activity == [true, false])
        #expect(transcript.renderFrom(index: 0).text == "[00:01-00:02] me: usable")
    }

    @Test func silenceUsesTheSharedTranscriptClock() async {
        let transcript = RollingTranscript()
        let clock = ManualClock(now: 0)
        let events = CoachingEvents()
        let coordinator = makeCoordinator(
            transcript: transcript,
            clock: clock,
            sessionStart: 0,
            silenceTimeout: 0.01,
            silenceEnabled: true,
            events: events)

        clock.set(1)
        coordinator.start()
        #expect(await waitUntil { events.silenceCount > 0 })
        coordinator.stop()

        #expect(events.firstSilence == 1)
    }

    @Test func stoppedSpeakerCannotSuppressRemainingStreamsSilence() {
        let transcript = RollingTranscript()
        let clock = ManualClock(now: 20)
        func coordinator(_ speaker: Speaker) -> TranscriptionCoachingCoordinator {
            TranscriptionCoachingCoordinator(
                speaker: speaker, transcript: transcript, clock: clock, sessionStart: 0,
                transcriptBatchingWindow: 0, silenceTimeout: 60, silenceMaxInterval: 120,
                silenceEnabled: false, onTurnEnd: { _ in }, onSilence: { _ in },
                onTranscriptionWorkChanged: { _ in })
        }
        let mic = coordinator(.me)
        let system = coordinator(.them)
        mic.start()
        system.start()
        system.recordLocalSpeech(.started(at: 4))
        mic.recordLocalSpeech(.ended(startedAt: 5, endedAt: 8, commitAt: 9))
        #expect(transcript.silenceDuration(now: 20) == 0)
        system.stop()
        #expect(transcript.silenceDuration(now: 20) == 12)
        mic.recordFinalizedTranscript("delayed words", spokenAt: 100, spokenEndAt: 1e20, source: "test")
        #expect(transcript.silenceDuration(now: 20) == 12)
        system.start()
        #expect(transcript.silenceDuration(now: 20) == 12)
        mic.stop()
        system.stop()
    }

    @Test func finalizedQuestionPublishesWhileLaterSpeechIsPending() async {
        let events = CoachingEvents()
        let coordinator = makeCoordinator(
            transcript: RollingTranscript(), clock: ManualClock(now: 3), sessionStart: 0,
            transcriptBatchingWindow: 0, events: events)
        coordinator.start()
        coordinator.updateTranscriptionWork(.pending(since: 2))
        coordinator.recordFinalizedTranscript("What is the complexity?", spokenAt: 1, spokenEndAt: 1, source: "test")
        #expect(await waitUntil { events.turnCount == 1 })
        #expect(events.firstTurnBoundary == 1)
        coordinator.stop()
    }

    @Test func pendingBoundaryAdvanceReleasesCompletedQuestionWithoutFullSettlement() async throws {
        let events = CoachingEvents()
        let coordinator = makeCoordinator(
            transcript: RollingTranscript(), clock: ManualClock(now: 3), sessionStart: 0,
            transcriptBatchingWindow: 0, events: events)
        let pending = try #require(PendingTurnProbe(coordinator))
        coordinator.start()
        coordinator.updateTranscriptionWork(.pending(since: 1))
        coordinator.recordFinalizedTranscript("What is the complexity?", spokenAt: 2, spokenEndAt: 2, source: "test")
        #expect(await waitUntil { pending.observeAndRestoreWaitingState() })
        #expect(events.turnCount == 0)
        coordinator.updateTranscriptionWork(.pending(since: 3))
        #expect(await waitUntil { events.turnCount == 1 })
        #expect(events.firstTurnBoundary == 1)
        coordinator.stop()
    }

    private func makeCoordinator(
        transcript: RollingTranscript,
        clock: Clock,
        sessionStart: TimeInterval,
        transcriptBatchingWindow: TimeInterval = 0.01,
        silenceTimeout: TimeInterval = 60,
        silenceEnabled: Bool = false,
        events: CoachingEvents
    ) -> TranscriptionCoachingCoordinator {
        TranscriptionCoachingCoordinator(
            speaker: .me,
            transcript: transcript,
            clock: clock,
            sessionStart: sessionStart,
            transcriptBatchingWindow: transcriptBatchingWindow,
            silenceTimeout: silenceTimeout,
            silenceMaxInterval: silenceTimeout,
            silenceEnabled: silenceEnabled,
            onTurnEnd: { events.recordTurn(boundary: $0) },
            onSilence: { events.recordSilence($0) },
            onTranscriptionWorkChanged: { events.recordActivity($0 != .settled) })
    }
}

/// @unchecked: lock guards every recorded value.
private final class CoachingEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var turns = 0
    private var turnBoundaries: [Int] = []
    private var silences: [TimeInterval] = []
    private var activityValues: [Bool] = []

    var turnCount: Int {
        lock.lock(); defer { lock.unlock() }
        return turns
    }

    var firstTurnBoundary: Int? {
        lock.lock(); defer { lock.unlock() }
        return turnBoundaries.first
    }

    var silenceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return silences.count
    }

    var firstSilence: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return silences.first
    }

    var activity: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return activityValues
    }

    func recordTurn(boundary: Int) {
        lock.lock()
        turns += 1
        turnBoundaries.append(boundary)
        lock.unlock()
    }

    func recordSilence(_ quiet: TimeInterval) {
        lock.lock()
        silences.append(quiet)
        lock.unlock()
    }

    func recordActivity(_ active: Bool) {
        lock.lock()
        activityValues.append(active)
        lock.unlock()
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - startedAt < timeoutNanoseconds {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// Queued after the batch's deadline on the same queue, so reaching it proves the invalidated
/// batch callback already ran, even under parallel test load.
private func waitForMainQueue(after delay: TimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            continuation.resume()
        }
    }
}

/// The batch has no visible callback while transcription is active, so this reads the private
/// buffer. It restores the waiting state so `updateTranscriptionWork(.settled)` still exercises the
/// resume path.
private struct PendingTurnProbe: Sendable {
    private let pending: UtteranceBuffer

    init?(_ coordinator: TranscriptionCoachingCoordinator) {
        guard let pending = Mirror(reflecting: coordinator).descendant("pending")
            as? UtteranceBuffer else { return nil }
        self.pending = pending
    }

    func observeAndRestoreWaitingState() -> Bool {
        guard pending.shouldResumeAfterPendingTranscriptionsSettle(
            hasPendingTranscriptions: false
        ) else { return false }
        return pending.drainIfSettled(hasPendingTranscriptions: true)
            == .waitingForPendingTranscriptions
    }
}

/// One main-actor turn keeps the batch callback queued until `stop()` invalidates it.
@MainActor
private func recordAndStopBeforeQueuedBatchRuns(
    _ coordinator: TranscriptionCoachingCoordinator
) -> (empty: Bool, usable: Bool) {
    coordinator.start()
    let empty = coordinator.recordFinalizedTranscript(" … ", spokenAt: nil, spokenEndAt: nil, source: "test")
    coordinator.updateTranscriptionWork(.pending(since: nil))
    let usable = coordinator.recordFinalizedTranscript("usable", spokenAt: 1, spokenEndAt: 2, source: "test")
    coordinator.stop()
    return (empty, usable)
}


extension TranscriptionCoachingCoordinatorTests {
    @Test func missingOrInvalidTimingPreservesWordsAndQueuesATurn() async {
        let transcript = RollingTranscript()
        let events = CoachingEvents()
        let coordinator = makeCoordinator(transcript: transcript, clock: ManualClock(now: 50),
            sessionStart: 0, transcriptBatchingWindow: 0, events: events)
        coordinator.start()
        for end: Double? in [nil, .nan, 1] {
            #expect(coordinator.recordFinalizedTranscript("untimed words", spokenAt: 2, spokenEndAt: end, source: "test"))
        }
        await waitForMainQueue(after: 0.02)
        #expect(transcript.count == 3)
        #expect(transcript.renderFrom(index: 0).text.components(separatedBy: "[00:02-00:02]").count == 4)
        #expect(events.turnCount > 0)
        coordinator.stop()
    }
}
