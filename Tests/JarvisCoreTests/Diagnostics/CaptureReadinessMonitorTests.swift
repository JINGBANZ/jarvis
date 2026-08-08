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
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        // Ready provider sessions are not proof of capture: with no positive-sample callbacks, full
        // listening remains unavailable and nothing fails before the deadline.
        #expect(!monitor.hasFirstFrame(.microphone))
        #expect(!monitor.hasFirstFrame(.system))
        #expect(monitor.readiness == .waitingForMicrophone)
        #expect(monitor.poll(at: 1).isEmpty)
        #expect(monitor.poll(at: 4.9).isEmpty)
    }

    @Test func positiveSampleCountEstablishesHealthWithoutAmplitudeInput() {
        let monitor = makeMonitor()
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        // The policy receives sample count but no amplitude or PCM, so this positive-count observation
        // represents both audible and all-zero digital-silence frames.
        #expect(monitor.note(
            .captured(sampleCount: 480), for: .microphone, at: 0.2).isEmpty)
        #expect(monitor.note(
            .captured(sampleCount: 480), for: .system, at: 0.2).isEmpty)
        #expect(monitor.hasFirstFrame(.microphone))
        #expect(monitor.hasFirstFrame(.system))
        #expect(monitor.readiness == .ready)
        #expect(monitor.poll(at: 100).isEmpty)
    }

    @Test func zeroSampleCallbackDoesNotEstablishCaptureHealth() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        #expect(monitor.note(.captured(sampleCount: 0), for: .microphone, at: 1).isEmpty)
        #expect(!monitor.hasFirstFrame(.microphone))
        #expect(monitor.readiness == .waitingForMicrophone)
        #expect(monitor.poll(at: 5) == [.microphoneCaptureFailed(.firstFrameTimeout)])
    }

    @Test func microphoneFirstFrameTimeoutIsTerminal() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        #expect(monitor.poll(at: 4.9).isEmpty)
        #expect(monitor.poll(at: 5) == [.microphoneCaptureFailed(.firstFrameTimeout)])
    }

    @Test func systemFirstFrameTimeoutDegradesToMicrophoneOnly() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        _ = monitor.note(.captured(sampleCount: 480), for: .microphone, at: 0.3)
        // Only the system stream is missing frames: degrade, don't stop.
        #expect(monitor.poll(at: 5) == [.degradeToMicrophoneOnly(.firstFrameTimeout)])
        #expect(monitor.isSystemUnavailable)
        #expect(monitor.readiness == .microphoneOnly)
        // The microphone stays healthy and no further system consequence repeats.
        #expect(monitor.poll(at: 20).isEmpty)
        #expect(monitor.hasFirstFrame(.microphone))
    }

    @Test func microphoneAndSystemFirstFramesAreIndependent() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        _ = monitor.note(.captured(sampleCount: 480), for: .microphone, at: 0.3)
        #expect(monitor.hasFirstFrame(.microphone))
        #expect(!monitor.hasFirstFrame(.system))
        #expect(monitor.readiness == .waitingForSystem)
        _ = monitor.note(.captured(sampleCount: 480), for: .system, at: 3)
        #expect(monitor.hasFirstFrame(.system))
        #expect(monitor.readiness == .ready)
        #expect(monitor.poll(at: 100).isEmpty)
    }

    @Test func providerReconnectDoesNotDiscardEstablishedFrameHealth() {
        let monitor = makeMonitor()
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        _ = monitor.note(.captured(sampleCount: 480), for: .microphone, at: 0.3)
        _ = monitor.note(.captured(sampleCount: 480), for: .system, at: 0.3)
        #expect(monitor.readiness == .ready)

        monitor.setProviderReady(false, for: .system)
        #expect(monitor.readiness == .waitingForSystem)
        monitor.setProviderReady(true, for: .system)
        #expect(monitor.readiness == .ready)
        #expect(monitor.hasFirstFrame(.system))
    }

    @Test func sustainedStallAfterReadinessFailsMicrophone() {
        let monitor = makeMonitor(sustainedStallTimeout: 10)
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        _ = monitor.note(.captured(sampleCount: 480), for: .microphone, at: 0.3)
        _ = monitor.note(.captured(sampleCount: 480), for: .system, at: 0.3)
        #expect(monitor.readiness == .ready)
        // A stall begins at t=12; a normal short gap must ride through until the sustained deadline.
        #expect(monitor.note(.stalled, for: .microphone, at: 12).isEmpty)
        #expect(monitor.poll(at: 21.9).isEmpty)
        #expect(monitor.poll(at: 22) == [.microphoneCaptureFailed(.sustainedStall)])
    }

    @Test func sustainedStallAfterReadinessDegradesSystem() {
        let monitor = makeMonitor(sustainedStallTimeout: 10)
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        _ = monitor.note(.captured(sampleCount: 480), for: .microphone, at: 0.3)
        _ = monitor.note(.captured(sampleCount: 480), for: .system, at: 0.3)
        #expect(monitor.readiness == .ready)
        _ = monitor.note(.stalled, for: .system, at: 12)
        #expect(monitor.poll(at: 22) == [.degradeToMicrophoneOnly(.sustainedStall)])
        #expect(monitor.isSystemUnavailable)
    }

    @Test func resumedCaptureClearsAStallBeforeItEscalates() {
        let monitor = makeMonitor(sustainedStallTimeout: 10)
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        _ = monitor.note(.captured(sampleCount: 480), for: .microphone, at: 0.3)
        _ = monitor.note(.captured(sampleCount: 480), for: .system, at: 0.3)
        #expect(monitor.readiness == .ready)
        _ = monitor.note(.stalled, for: .microphone, at: 12)
        #expect(monitor.note(
            .captured(sampleCount: 480), for: .microphone, at: 15).isEmpty)
        // The stall is cleared, so the old deadline no longer applies.
        #expect(monitor.poll(at: 100).isEmpty)
    }

    @Test func routeRecoveryOwnsFailureUntilItsRetryIncidentFinishes() {
        let monitor = makeMonitor(firstFrameTimeout: 5, sustainedStallTimeout: 10)
        _ = monitor.note(.captured(sampleCount: 480), for: .microphone, at: 0.3)
        _ = monitor.note(.captured(sampleCount: 480), for: .system, at: 0.3)
        _ = monitor.note(.stalled, for: .microphone, at: 3)
        monitor.setCaptureRecoveryInProgress(true, at: 4)

        // AggregateEchoCapture's bounded rebuild incident is authoritative while it is active.
        #expect(monitor.poll(at: 100).isEmpty)
        monitor.setCaptureRecoveryInProgress(false, at: 100)
        // No fresh frame arrived during recovery, so the consequence gets a complete post-rebuild
        // window instead of firing immediately from the pre-rebuild stall.
        #expect(monitor.poll(at: 109.9).isEmpty)
        #expect(monitor.poll(at: 110) == [.microphoneCaptureFailed(.sustainedStall)])
    }

    @Test func firstFrameDeadlineAlsoRestartsAfterRouteRecovery() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        monitor.setCaptureRecoveryInProgress(true, at: 4)
        #expect(monitor.poll(at: 100).isEmpty)
        monitor.setCaptureRecoveryInProgress(false, at: 100)
        #expect(monitor.poll(at: 104.9).isEmpty)
        #expect(monitor.poll(at: 105) == [.microphoneCaptureFailed(.firstFrameTimeout)])
    }

    @Test func shortRouteRecoveryDoesNotInventAStallWithoutWitnessEvidence() {
        let monitor = makeMonitor(sustainedStallTimeout: 10)
        _ = monitor.note(.captured(sampleCount: 480), for: .microphone, at: 0.3)
        _ = monitor.note(.captured(sampleCount: 480), for: .system, at: 0.3)
        monitor.setCaptureRecoveryInProgress(true, at: 1)
        monitor.setCaptureRecoveryInProgress(false, at: 1.5)

        // A short rebuild can finish before AudioContinuityWitness observes a stall. Recovery must
        // not manufacture one; if frames truly remain absent, the witness will report it later.
        #expect(monitor.poll(at: 100).isEmpty)
        #expect(monitor.note(.stalled, for: .microphone, at: 101).isEmpty)
        #expect(monitor.poll(at: 111) == [.microphoneCaptureFailed(.sustainedStall)])
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
        monitor.setProviderReady(true, for: .microphone)
        #expect(monitor.note(
            .captured(sampleCount: 480), for: .microphone, at: 6).isEmpty)
        #expect(!monitor.hasFirstFrame(.microphone))
        #expect(monitor.readiness == .stopped)
        #expect(monitor.poll(at: 30).isEmpty)
    }

    @Test func systemBecameUnavailableStopsItsCaptureTimeout() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        monitor.setProviderReady(true, for: .microphone)
        _ = monitor.note(.captured(sampleCount: 480), for: .microphone, at: 0.3)
        monitor.systemBecameUnavailable()
        #expect(monitor.isSystemUnavailable)
        #expect(monitor.readiness == .microphoneOnly)
        // The system stream is no longer required, so its missing first frame raises nothing.
        #expect(monitor.poll(at: 30).isEmpty)
    }

    @Test func microphoneOnlyConfigurationIgnoresTheSystemStream() {
        let monitor = makeMonitor(firstFrameTimeout: 5, requiresSystemAudio: false)
        monitor.setProviderReady(true, for: .microphone)
        _ = monitor.note(.captured(sampleCount: 480), for: .microphone, at: 0.3)
        // System audio is not required, so it never triggers a degrade even without frames.
        #expect(monitor.poll(at: 30).isEmpty)
        #expect(!monitor.isSystemUnavailable)
        #expect(monitor.readiness == .microphoneOnly)
    }

    @Test func resolvedSystemStreamIgnoresLaterStalls() {
        let monitor = makeMonitor()
        monitor.setProviderReady(true, for: .microphone)
        _ = monitor.note(.captured(sampleCount: 480), for: .microphone, at: 0.3)
        monitor.systemBecameUnavailable()
        monitor.setProviderReady(true, for: .system)
        #expect(monitor.note(
            .captured(sampleCount: 480), for: .system, at: 30).isEmpty)
        #expect(monitor.note(.stalled, for: .system, at: 40).isEmpty)
        #expect(monitor.poll(at: 60).isEmpty)
        #expect(monitor.readiness == .microphoneOnly)
    }
}
