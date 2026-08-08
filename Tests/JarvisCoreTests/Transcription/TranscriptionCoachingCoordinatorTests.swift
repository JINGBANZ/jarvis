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
            turnDebounce: 0,
            events: events)

        coordinator.start()
        coordinator.updateActivity(true)
        #expect(coordinator.recordFinalizedTranscript(
            "  first fragment  ", spokenAt: 1, source: "test"))
        #expect(coordinator.recordFinalizedTranscript(
            "second fragment", spokenAt: 2, source: "test"))

        await drainMainQueue()
        #expect(events.turnCount == 0)
        #expect(events.activity == [true])

        coordinator.updateActivity(false)
        #expect(await waitUntil { events.turnCount == 1 })
        #expect(events.activity == [true, false])
        #expect(transcript.renderFrom(index: 0).text
            == "[00:01] me: first fragment\n[00:02] me: second fragment")
        coordinator.stop()
    }

    @Test func rejectsEmptyFinalsAndStopCancelsPendingTurn() async {
        let transcript = RollingTranscript()
        let clock = ManualClock(now: 10)
        let events = CoachingEvents()
        let coordinator = makeCoordinator(
            transcript: transcript,
            clock: clock,
            sessionStart: 10,
            turnDebounce: 0,
            events: events)

        let accepted = await recordAndStopBeforeQueuedDebounceRuns(coordinator)
        #expect(!accepted.empty)
        #expect(accepted.usable)

        await drainMainQueue()
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
        turnDebounce: TimeInterval = 0.01,
        silenceTimeout: TimeInterval = 60,
        silenceEnabled: Bool = false,
        events: CoachingEvents
    ) -> TranscriptionCoachingCoordinator {
        TranscriptionCoachingCoordinator(
            speaker: .me,
            transcript: transcript,
            clock: clock,
            sessionStart: sessionStart,
            turnDebounce: turnDebounce,
            silenceTimeout: silenceTimeout,
            silenceMaxInterval: silenceTimeout,
            silenceEnabled: silenceEnabled,
            onTurnEnd: { events.recordTurn() },
            onSilence: { events.recordSilence($0) },
            onSpeechActivityChanged: { events.recordActivity($0) })
    }
}

/// `@unchecked Sendable`: `lock` guards every read and write of the recorded callback values.
private final class CoachingEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var turns = 0
    private var silences: [TimeInterval] = []
    private var activityValues: [Bool] = []

    var turnCount: Int {
        lock.lock(); defer { lock.unlock() }
        return turns
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

    func recordTurn() {
        lock.lock()
        turns += 1
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

/// The zero-delay debounce has already submitted its work to this serial queue. A later sentinel
/// proves that the scheduled turn had a chance to run, without guessing how many milliseconds the
/// main actor needs under the parallel suite.
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

/// Running the complete start/record/stop sequence in one main-actor turn guarantees the
/// zero-delay debounce is genuinely queued but cannot execute until after `stop()` invalidates it.
@MainActor
private func recordAndStopBeforeQueuedDebounceRuns(
    _ coordinator: TranscriptionCoachingCoordinator
) -> (empty: Bool, usable: Bool) {
    coordinator.start()
    let empty = coordinator.recordFinalizedTranscript(" … ", spokenAt: nil, source: "test")
    coordinator.updateActivity(true)
    let usable = coordinator.recordFinalizedTranscript("usable", spokenAt: nil, source: "test")
    coordinator.stop()
    return (empty, usable)
}
