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
        #expect(monitor.note(
            .frames(sampleCount: 480), for: .microphone, at: 0.2).isEmpty)
        #expect(monitor.note(
            .frames(sampleCount: 480), for: .system, at: 0.2).isEmpty)
        #expect(monitor.hasFirstFrame(.microphone))
        #expect(monitor.hasFirstFrame(.system))
        #expect(monitor.readiness == .ready)
        #expect(monitor.poll(at: 100).isEmpty)
    }

    @Test func zeroSampleCallbackDoesNotEstablishCaptureHealth() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        #expect(monitor.note(.frames(sampleCount: 0), for: .microphone, at: 1).isEmpty)
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
        _ = monitor.note(.frames(sampleCount: 480), for: .microphone, at: 0.3)
        #expect(monitor.poll(at: 5) == [.degradeToMicrophoneOnly(.firstFrameTimeout)])
        #expect(monitor.isSystemUnavailable)
        #expect(monitor.readiness == .microphoneOnly)
        #expect(monitor.poll(at: 20).isEmpty)
        #expect(monitor.hasFirstFrame(.microphone))
    }

    @Test func microphoneAndSystemFirstFramesAreIndependent() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        _ = monitor.note(.frames(sampleCount: 480), for: .microphone, at: 0.3)
        #expect(monitor.hasFirstFrame(.microphone))
        #expect(!monitor.hasFirstFrame(.system))
        #expect(monitor.readiness == .waitingForSystem)
        _ = monitor.note(.frames(sampleCount: 480), for: .system, at: 3)
        #expect(monitor.hasFirstFrame(.system))
        #expect(monitor.readiness == .ready)
        #expect(monitor.poll(at: 100).isEmpty)
    }

    @Test func providerReconnectDoesNotDiscardEstablishedFrameHealth() {
        let monitor = makeMonitor()
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        _ = monitor.note(.frames(sampleCount: 480), for: .microphone, at: 0.3)
        _ = monitor.note(.frames(sampleCount: 480), for: .system, at: 0.3)
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
        _ = monitor.note(.frames(sampleCount: 480), for: .microphone, at: 0.3)
        _ = monitor.note(.frames(sampleCount: 480), for: .system, at: 0.3)
        #expect(monitor.readiness == .ready)
        #expect(monitor.note(.stalled, for: .microphone, at: 12).isEmpty)
        #expect(monitor.poll(at: 21.9).isEmpty)
        #expect(monitor.poll(at: 22) == [.microphoneCaptureFailed(.sustainedStall)])
    }

    @Test func sustainedStallAfterReadinessDegradesSystem() {
        let monitor = makeMonitor(sustainedStallTimeout: 10)
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        _ = monitor.note(.frames(sampleCount: 480), for: .microphone, at: 0.3)
        _ = monitor.note(.frames(sampleCount: 480), for: .system, at: 0.3)
        #expect(monitor.readiness == .ready)
        _ = monitor.note(.stalled, for: .system, at: 12)
        #expect(monitor.poll(at: 22) == [.degradeToMicrophoneOnly(.sustainedStall)])
        #expect(monitor.isSystemUnavailable)
    }

    @Test func resumedCaptureClearsAStallBeforeItEscalates() {
        let monitor = makeMonitor(sustainedStallTimeout: 10)
        monitor.setProviderReady(true, for: .microphone)
        monitor.setProviderReady(true, for: .system)
        _ = monitor.note(.frames(sampleCount: 480), for: .microphone, at: 0.3)
        _ = monitor.note(.frames(sampleCount: 480), for: .system, at: 0.3)
        #expect(monitor.readiness == .ready)
        _ = monitor.note(.stalled, for: .microphone, at: 12)
        #expect(monitor.note(
            .frames(sampleCount: 480), for: .microphone, at: 15).isEmpty)
        #expect(monitor.poll(at: 100).isEmpty)
    }

    @Test func routeRecoveryOwnsFailureUntilItsRetryIncidentFinishes() {
        let monitor = makeMonitor(firstFrameTimeout: 5, sustainedStallTimeout: 10)
        _ = monitor.note(.frames(sampleCount: 480), for: .microphone, at: 0.3)
        _ = monitor.note(.frames(sampleCount: 480), for: .system, at: 0.3)
        _ = monitor.note(.stalled, for: .microphone, at: 3)
        monitor.setCaptureRecoveryInProgress(true, at: 4)

        #expect(monitor.poll(at: 100).isEmpty)
        monitor.setCaptureRecoveryInProgress(false, at: 100)
        // The stall window restarts when recovery ends at 100, not at the pre-rebuild stall at 3.
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
        _ = monitor.note(.frames(sampleCount: 480), for: .microphone, at: 0.3)
        _ = monitor.note(.frames(sampleCount: 480), for: .system, at: 0.3)
        monitor.setCaptureRecoveryInProgress(true, at: 1)
        monitor.setCaptureRecoveryInProgress(false, at: 1.5)

        #expect(monitor.poll(at: 100).isEmpty)
        #expect(monitor.note(.stalled, for: .microphone, at: 101).isEmpty)
        #expect(monitor.poll(at: 111) == [.microphoneCaptureFailed(.sustainedStall)])
    }

    @Test func stallWhilePendingIsGovernedByTheFirstFrameDeadline() {
        let monitor = makeMonitor(firstFrameTimeout: 5, sustainedStallTimeout: 10)
        #expect(monitor.note(.stalled, for: .microphone, at: 2).isEmpty)
        #expect(monitor.poll(at: 4.9).isEmpty)
        #expect(monitor.poll(at: 5) == [.microphoneCaptureFailed(.firstFrameTimeout)])
    }

    @Test func microphoneFailureSupersedesSystemDegradationOnTheSameTick() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        #expect(monitor.poll(at: 5) == [.microphoneCaptureFailed(.firstFrameTimeout)])
    }

    @Test func lateOrDuplicateObservationsCannotResurrectAStoppedSession() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        #expect(monitor.poll(at: 5) == [.microphoneCaptureFailed(.firstFrameTimeout)])
        monitor.setProviderReady(true, for: .microphone)
        #expect(monitor.note(
            .frames(sampleCount: 480), for: .microphone, at: 6).isEmpty)
        #expect(!monitor.hasFirstFrame(.microphone))
        #expect(monitor.readiness == .stopped)
        #expect(monitor.poll(at: 30).isEmpty)
    }

    @Test func systemBecameUnavailableStopsItsCaptureTimeout() {
        let monitor = makeMonitor(firstFrameTimeout: 5)
        monitor.setProviderReady(true, for: .microphone)
        _ = monitor.note(.frames(sampleCount: 480), for: .microphone, at: 0.3)
        monitor.systemBecameUnavailable()
        #expect(monitor.isSystemUnavailable)
        #expect(monitor.readiness == .microphoneOnly)
        #expect(monitor.poll(at: 30).isEmpty)
    }

    @Test func microphoneOnlyConfigurationIgnoresTheSystemStream() {
        let monitor = makeMonitor(firstFrameTimeout: 5, requiresSystemAudio: false)
        monitor.setProviderReady(true, for: .microphone)
        _ = monitor.note(.frames(sampleCount: 480), for: .microphone, at: 0.3)
        #expect(monitor.poll(at: 30).isEmpty)
        #expect(!monitor.isSystemUnavailable)
        #expect(monitor.readiness == .microphoneOnly)
    }

    @Test func resolvedSystemStreamIgnoresLaterStalls() {
        let monitor = makeMonitor()
        monitor.setProviderReady(true, for: .microphone)
        _ = monitor.note(.frames(sampleCount: 480), for: .microphone, at: 0.3)
        monitor.systemBecameUnavailable()
        monitor.setProviderReady(true, for: .system)
        #expect(monitor.note(
            .frames(sampleCount: 480), for: .system, at: 30).isEmpty)
        #expect(monitor.note(.stalled, for: .system, at: 40).isEmpty)
        #expect(monitor.poll(at: 60).isEmpty)
        #expect(monitor.readiness == .microphoneOnly)
    }
}
