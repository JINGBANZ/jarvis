import Foundation
import Testing
@testable import JarvisCore

@Suite struct TranscriptionBenchmarkIsolationTests {
    @Test func absentInstrumentationDoesNotConstructAnEvent() {
        let instrumentation: TranscriptionBenchmarkInstrumentation? = nil
        var eventWasConstructed = false

        instrumentation?.observer.record(event(marking: &eventWasConstructed))

        #expect(!eventWasConstructed)
    }

    @Test func transportControlHoldsOneReconnectUntilReleased() {
        let control = TranscriptionBenchmarkTransportControl()
        let reconnectCount = LockedCounter()
        control.installInterruption { true }

        #expect(control.beginInterruption())
        control.runReconnectWhenReleased { reconnectCount.increment() }
        control.runReconnectWhenReleased { reconnectCount.increment() }
        #expect(reconnectCount.value == 0)

        control.endInterruption()
        control.endInterruption()
        #expect(reconnectCount.value == 1)
    }

    @Test func failedInterruptionCannotHoldReconnect() {
        let control = TranscriptionBenchmarkTransportControl()
        let reconnectCount = LockedCounter()
        control.installInterruption { false }

        #expect(!control.beginInterruption())
        control.runReconnectWhenReleased { reconnectCount.increment() }

        #expect(reconnectCount.value == 1)
    }

    @Test func uninstallDropsADeferredReconnectAndRemovesTheFaultCapability() {
        let control = TranscriptionBenchmarkTransportControl()
        let reconnectCount = LockedCounter()
        control.installInterruption { true }
        #expect(control.beginInterruption())
        control.runReconnectWhenReleased { reconnectCount.increment() }

        control.uninstallInterruption()
        control.endInterruption()

        #expect(reconnectCount.value == 0)
        #expect(!control.beginInterruption())
    }

    private func event(marking flag: inout Bool) -> TranscriptionBenchmarkEvent {
        flag = true
        return .init(
            kind: .ready,
            provider: "test",
            speaker: "them",
            generation: 1,
            observedAt: 0)
    }

    /// `@unchecked Sendable`: `lock` protects the integer.
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func increment() {
            lock.lock(); storage += 1; lock.unlock()
        }
    }
}
