import Foundation
import Testing
@testable import JarvisCore

@Suite struct CaptureReadinessMonitorTests {
    private func makeMonitor(
        firstFrameTimeout: TimeInterval = 5,
        sustainedStallTimeout: TimeInterval = 10,
        requiresSystemAudio: Bool = true
    ) -> CaptureReadinessMonitor {
        CaptureReadinessMonitor(
            configuration: .init(firstFrameTimeout: firstFrameTimeout,
                                 sustainedStallTimeout: sustainedStallTimeout),
            requiresSystemAudio: requiresSystemAudio,
            startedAt: 0)
    }

    @Test func readyProviderWithZeroFramesNeverReportsFirstFrame() {
        let monitor = makeMonitor()
        // A ready provider session is not proof of capture: with no delivered frames, neither stream
        // has a first frame and nothing yet fails.
        #expect(!monitor.hasFirstFrame(.microphone))
        #expect(!monitor.hasFirstFrame(.system))
        #expect(monitor.poll(at: 1).isEmpty)
        #expect(monitor.poll(at: 4.9).isEmpty)
    }

    @Test func zeroAmplitudeFrameEstablishesCaptureHealth() {
        let monitor = makeMonitor()
        // A silent (zero-amplitude) frame is still a delivered frame — arrival, not amplitude, is health.
        #expect(monitor.note(.firstFrame, for: .microphone, at: 0.2).isEmpty)
        #expect(monitor.note(.firstFrame, for: .system, at: 0.2).isEmpty)
        #expect(monitor.hasFirstFrame(.microphone))
        #expect(monitor.hasFirstFrame(.system))
        #expect(monitor.poll(at: 100).isEmpty)
    }

    @Test func microphoneFirstFrameTimeoutIsTerminal() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        #expect(monitor.poll(at: 4.9).isEmpty)
        #expect(monitor.poll(at: 5) == [.microphoneCaptureFailed(.firstFrameTimeout)])
    }

    @Test func systemFirstFrameTimeoutDegradesToMicrophoneOnly() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        _ = monitor.note(.firstFrame, for: .microphone, at: 0.3)
        // Only the system stream is missing frames: degrade, don't stop.
        #expect(monitor.poll(at: 5) == [.degradeToMicrophoneOnly(.firstFrameTimeout)])
        #expect(monitor.isSystemUnavailable)
        // The microphone stays healthy and no further system consequence repeats.
        #expect(monitor.poll(at: 20).isEmpty)
        #expect(monitor.hasFirstFrame(.microphone))
    }

    @Test func microphoneAndSystemFirstFramesAreIndependent() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        _ = monitor.note(.firstFrame, for: .microphone, at: 0.3)
        #expect(monitor.hasFirstFrame(.microphone))
        #expect(!monitor.hasFirstFrame(.system))
        _ = monitor.note(.firstFrame, for: .system, at: 3)
        #expect(monitor.hasFirstFrame(.system))
        #expect(monitor.poll(at: 100).isEmpty)
    }

    @Test func sustainedStallAfterReadinessFailsMicrophone() {
        let monitor = makeMonitor(sustainedStallTimeout: 10)
        _ = monitor.note(.firstFrame, for: .microphone, at: 0.3)
        _ = monitor.note(.firstFrame, for: .system, at: 0.3)
        // A stall begins at t=12; a normal short gap must ride through until the sustained deadline.
        #expect(monitor.note(.stalled, for: .microphone, at: 12).isEmpty)
        #expect(monitor.poll(at: 21.9).isEmpty)
        #expect(monitor.poll(at: 22) == [.microphoneCaptureFailed(.sustainedStall)])
    }

    @Test func sustainedStallAfterReadinessDegradesSystem() {
        let monitor = makeMonitor(sustainedStallTimeout: 10)
        _ = monitor.note(.firstFrame, for: .microphone, at: 0.3)
        _ = monitor.note(.firstFrame, for: .system, at: 0.3)
        _ = monitor.note(.stalled, for: .system, at: 12)
        #expect(monitor.poll(at: 22) == [.degradeToMicrophoneOnly(.sustainedStall)])
        #expect(monitor.isSystemUnavailable)
    }

    @Test func resumedCaptureClearsAStallBeforeItEscalates() {
        let monitor = makeMonitor(sustainedStallTimeout: 10)
        _ = monitor.note(.firstFrame, for: .microphone, at: 0.3)
        _ = monitor.note(.firstFrame, for: .system, at: 0.3)
        _ = monitor.note(.stalled, for: .microphone, at: 12)
        #expect(monitor.note(.resumed, for: .microphone, at: 15).isEmpty)
        // The stall is cleared, so the old deadline no longer applies.
        #expect(monitor.poll(at: 100).isEmpty)
    }

    @Test func stallWhilePendingIsGovernedByTheFirstFrameDeadline() {
        let monitor = makeMonitor(firstFrameTimeout: 5, sustainedStallTimeout: 10)
        // A stall before any frame must not use the sustained-stall timeout; the first-frame deadline
        // owns the pending case.
        #expect(monitor.note(.stalled, for: .microphone, at: 2).isEmpty)
        #expect(monitor.poll(at: 4.9).isEmpty)
        #expect(monitor.poll(at: 5) == [.microphoneCaptureFailed(.firstFrameTimeout)])
    }

    @Test func microphoneFailureSupersedesSystemDegradationOnTheSameTick() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        // Neither stream ever delivers a frame: only the terminal microphone failure surfaces.
        #expect(monitor.poll(at: 5) == [.microphoneCaptureFailed(.firstFrameTimeout)])
    }

    @Test func lateOrDuplicateObservationsCannotResurrectAStoppedSession() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        #expect(monitor.poll(at: 5) == [.microphoneCaptureFailed(.firstFrameTimeout)])
        // After the microphone fails the session is ending; nothing can re-arm readiness.
        #expect(monitor.note(.firstFrame, for: .microphone, at: 6).isEmpty)
        #expect(!monitor.hasFirstFrame(.microphone))
        #expect(monitor.poll(at: 30).isEmpty)
    }

    @Test func systemBecameUnavailableStopsItsCaptureTimeout() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        _ = monitor.note(.firstFrame, for: .microphone, at: 0.3)
        monitor.systemBecameUnavailable()
        #expect(monitor.isSystemUnavailable)
        // The system stream is no longer required, so its missing first frame raises nothing.
        #expect(monitor.poll(at: 30).isEmpty)
    }

    @Test func microphoneOnlyConfigurationIgnoresTheSystemStream() {
        let monitor = makeMonitor(firstFrameTimeout: 5, requiresSystemAudio: false)
        _ = monitor.note(.firstFrame, for: .microphone, at: 0.3)
        // System audio is not required, so it never triggers a degrade even without frames.
        #expect(monitor.poll(at: 30).isEmpty)
        #expect(!monitor.isSystemUnavailable)
    }

    @Test func resolvedSystemStreamIgnoresLaterStalls() {
        let monitor = makeMonitor()
        _ = monitor.note(.firstFrame, for: .microphone, at: 0.3)
        monitor.systemBecameUnavailable()
        #expect(monitor.note(.stalled, for: .system, at: 40).isEmpty)
        #expect(monitor.poll(at: 60).isEmpty)
    }
}
