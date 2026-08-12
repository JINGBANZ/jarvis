import Foundation
import Testing
@testable import JarvisCore

@Suite struct TranscriptionCoachingCoordinatorTests {
    @Test func finalizedFragmentsWaitForActivityToSettleAndCoalesce() async {
        let transcript = RollingTranscript()
        let clock = ManualClock(now: 100)
        let events = CoachingEvents()
        let coordinator = makeCoordinator(
            transcript: transcript,
            clock: clock,
            sessionStart: 100,
            transcriptBatchingDelay: 0,
            events: events)
        guard let pendingTurn = PendingTurnProbe(coordinator) else {
            Issue.record("Could not inspect the coordinator's pending utterance buffer")
            return
        }

        coordinator.start()
        coordinator.updateTranscriptionWork(true)
        #expect(coordinator.recordFinalizedTranscript(
            "  first fragment  ", spokenAt: 1, source: "test"))
        #expect(coordinator.recordFinalizedTranscript(
            "second fragment", spokenAt: 2, source: "test"))

        #expect(await waitUntil {
            pendingTurn.observeAndRestoreWaitingState()
        })
        #expect(events.turnCount == 0)
        #expect(events.activity == [true])

        coordinator.updateTranscriptionWork(false)
        #expect(await waitUntil { events.turnCount == 1 })
        #expect(events.firstTurnBoundary == 2)
        #expect(events.activity == [true, false])
        #expect(transcript.renderFrom(index: 0).text
            == "[00:01] me: first fragment\n[00:02] me: second fragment")
        coordinator.stop()
    }

    @Test func rejectsEmptyFinalsAndStopCancelsPendingTurn() async {
        let transcript = RollingTranscript()
        let clock = ManualClock(now: 10)
        let events = CoachingEvents()
        let transcriptBatchingDelay: TimeInterval = 0.02
        let coordinator = makeCoordinator(
            transcript: transcript,
            clock: clock,
            sessionStart: 10,
            transcriptBatchingDelay: transcriptBatchingDelay,
            events: events)

        let accepted = await recordAndStopBeforeQueuedBatchRuns(coordinator)
        #expect(!accepted.empty)
        #expect(accepted.usable)

        await waitForMainQueue(after: transcriptBatchingDelay * 2)
        #expect(events.turnCount == 0)
        #expect(events.activity == [true, false])
        #expect(transcript.renderFrom(index: 0).text == "[00:00] me: usable")
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

    private func makeCoordinator(
        transcript: RollingTranscript,
        clock: Clock,
        sessionStart: TimeInterval,
        transcriptBatchingDelay: TimeInterval = 0.01,
        silenceTimeout: TimeInterval = 60,
        silenceEnabled: Bool = false,
        events: CoachingEvents
    ) -> TranscriptionCoachingCoordinator {
        TranscriptionCoachingCoordinator(
            speaker: .me,
            transcript: transcript,
            clock: clock,
            sessionStart: sessionStart,
            transcriptBatchingDelay: transcriptBatchingDelay,
            silenceTimeout: silenceTimeout,
            silenceMaxInterval: silenceTimeout,
            silenceEnabled: silenceEnabled,
            onTurnEnd: { events.recordTurn(boundary: $0) },
            onSilence: { events.recordSilence($0) },
            onTranscriptionWorkChanged: { events.recordActivity($0) })
    }
}

/// `@unchecked Sendable`: `lock` guards every read and write of the recorded callback values.
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

/// Production scheduled its transcript batch before this later-deadline marker on the same queue.
/// Reaching the marker proves the invalidated `publishTranscriptBatch` callback ran first, even when
/// parallel test load delays both callbacks beyond their deadlines.
private func waitForMainQueue(after delay: TimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            continuation.resume()
        }
    }
}

/// `publishTranscriptBatch` has no externally visible callback while transcription remains active. This
/// test-local probe observes the exact `UtteranceBuffer` transition instead of adding a production
/// hook, then restores the state so `updateTranscriptionWork(false)` exercises the resume path.
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

/// Running the complete start/record/stop sequence in one main-actor turn guarantees the batch callback
/// is genuinely queued but cannot execute until after `stop()` invalidates it.
@MainActor
private func recordAndStopBeforeQueuedBatchRuns(
    _ coordinator: TranscriptionCoachingCoordinator
) -> (empty: Bool, usable: Bool) {
    coordinator.start()
    let empty = coordinator.recordFinalizedTranscript(" … ", spokenAt: nil, source: "test")
    coordinator.updateTranscriptionWork(true)
    let usable = coordinator.recordFinalizedTranscript("usable", spokenAt: nil, source: "test")
    coordinator.stop()
    return (empty, usable)
}
