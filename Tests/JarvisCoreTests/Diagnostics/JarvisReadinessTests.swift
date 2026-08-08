import Foundation
import Testing
@testable import JarvisCore

@Suite struct JarvisReadinessTests {
    private let allRequirements = JarvisReadiness.Configuration(
        requiredCredentials: [.openAIAPIKey],
        requiresTranscriptionPreparation: true)

    @Test func mandatoryRequirementsCanCompleteInAnyOrder() {
        let readiness = JarvisReadiness()
        let start = readiness.begin(configuration: allRequirements)

        #expect(start.effects == [.statusChanged(.checking(.permissions))])

        // Live subsystems may finish before preflight. Their typed snapshots are retained, but they
        // cannot bypass an earlier mandatory requirement.
        _ = readiness.observe([
            .capture(.ready),
            .transcriptionEndpoint(stream: .system, state: .ready),
            .transcriptionEndpoint(stream: .microphone, state: .ready),
            .transcriptionPreparation(.ready),
            .brainPreparation(.ready),
            .credentials(available: [.openAIAPIKey]),
        ], for: start.session)
        #expect(readiness.status == .checking(.permissions))

        let effects = readiness.observe(
            .permissions(granted: [.microphone, .screenRecording]),
            for: start.session)
        #expect(readiness.status == .ready(.full))
        #expect(effects == [
            .statusChanged(.ready(.full)),
            .readinessEstablished(.full),
        ])

        let reverse = JarvisReadiness()
        let reverseStart = reverse.begin(configuration: allRequirements)
        _ = reverse.observe([
            .permissions(granted: [.microphone, .screenRecording]),
            .credentials(available: [.openAIAPIKey]),
            .brainPreparation(.ready),
            .transcriptionPreparation(.ready),
            .capture(.ready),
        ], for: reverseStart.session)
        #expect(reverse.status == .checking(.transcriptionEndpoints))
        _ = reverse.observe(
            .transcriptionEndpoint(stream: .microphone, state: .ready),
            for: reverseStart.session)
        #expect(reverse.status == .checking(.transcriptionEndpoints))
        _ = reverse.observe(
            .transcriptionEndpoint(stream: .system, state: .ready),
            for: reverseStart.session)
        #expect(reverse.status == .ready(.full))
    }

    @Test func everyMandatoryConditionGatesFullReadiness() {
        let readiness = JarvisReadiness()
        let start = readiness.begin(configuration: allRequirements)

        _ = readiness.observe(
            .permissions(granted: [.microphone, .screenRecording]), for: start.session)
        #expect(readiness.status == .checking(.credentials))
        _ = readiness.observe(
            .credentials(available: [.openAIAPIKey]), for: start.session)
        #expect(readiness.status == .checking(.brainPreparation))
        _ = readiness.observe(.brainPreparation(.ready), for: start.session)
        #expect(readiness.status == .checking(.transcriptionPreparation))
        _ = readiness.observe(.transcriptionPreparation(.ready), for: start.session)
        #expect(readiness.status == .checking(.transcriptionEndpoints))
        _ = readiness.observe([
            .transcriptionEndpoint(stream: .microphone, state: .ready),
            .transcriptionEndpoint(stream: .system, state: .ready),
        ], for: start.session)
        #expect(readiness.status == .checking(.capture))
        _ = readiness.observe(.capture(.waitingForSystem), for: start.session)
        #expect(readiness.status == .checking(.capture))
        _ = readiness.observe(.capture(.ready), for: start.session)
        #expect(readiness.status == .ready(.full))
    }

    @Test func microphoneOnlyIsAnExplicitDegradedReadyMode() {
        let readiness = JarvisReadiness()
        let start = readiness.begin(configuration: .init())
        _ = readiness.observe([
            .permissions(granted: [.microphone, .screenRecording]),
            .brainPreparation(.ready),
            .transcriptionEndpoint(stream: .microphone, state: .ready),
            .transcriptionEndpoint(stream: .system, state: .failed),
            .capture(.microphoneOnly),
        ], for: start.session)

        #expect(readiness.status == .ready(.microphoneOnly))
    }

    @Test func configuredMicrophoneOnlySessionDoesNotWaitForSystemAudio() {
        let readiness = JarvisReadiness()
        let start = readiness.begin(configuration: .init(requiresSystemAudio: false))
        _ = readiness.observe([
            .permissions(granted: [.microphone, .screenRecording]),
            .brainPreparation(.ready),
            .transcriptionEndpoint(stream: .microphone, state: .ready),
            .capture(.microphoneOnly),
        ], for: start.session)

        #expect(readiness.status == .ready(.microphoneOnly))
    }

    @Test func endpointAndCaptureRecoveryCannotReportReady() {
        let (readiness, session) = fullReadyReadiness()

        _ = readiness.observe(
            .transcriptionEndpoint(stream: .microphone, state: .reconnecting(attempt: 2)),
            for: session)
        #expect(readiness.status == .recovering(.transcriptionEndpoints, attempt: 2))
        // Capture's previous healthy snapshot is not enough while the endpoint owns recovery.
        #expect(readiness.observe(.capture(.ready), for: session).isEmpty)
        #expect(readiness.status == .recovering(.transcriptionEndpoints, attempt: 2))

        let endpointRecovered = readiness.observe(
            .transcriptionEndpoint(stream: .microphone, state: .ready), for: session)
        #expect(endpointRecovered == [
            .statusChanged(.ready(.full)),
            .readinessEstablished(.full),
        ])

        _ = readiness.observe(.captureRecovery(inProgress: true), for: session)
        #expect(readiness.status == .recovering(.capture, attempt: nil))
        _ = readiness.observe(.captureRecovery(inProgress: false), for: session)
        #expect(readiness.status == .ready(.full))
    }

    @Test func systemRecoveryCanDegradeAtomicallyToMicrophoneOnly() {
        let (readiness, session) = fullReadyReadiness()
        _ = readiness.observe(
            .transcriptionEndpoint(stream: .system, state: .reconnecting(attempt: 3)),
            for: session)
        #expect(readiness.status == .recovering(.transcriptionEndpoints, attempt: 3))

        let effects = readiness.observe([
            .transcriptionEndpoint(stream: .system, state: .failed),
            .capture(.microphoneOnly),
        ], for: session)
        #expect(effects == [
            .statusChanged(.ready(.microphoneOnly)),
            .readinessEstablished(.microphoneOnly),
        ])
    }

    @Test func blockedStartupIsTypedAndTerminalForThatAttempt() {
        let readiness = JarvisReadiness()
        let start = readiness.begin(configuration: allRequirements)
        let effects = readiness.observe(
            .permissions(granted: [.microphone]), for: start.session)

        #expect(effects == [
            .statusChanged(.blocked(.permissions([.screenRecording]))),
        ])
        // A permission callback or other late completion must not autonomously start the attempt the
        // user was already told was blocked. A new explicit Start gets a new token.
        #expect(readiness.observe([
            .permissions(granted: [.microphone, .screenRecording]),
            .credentials(available: [.openAIAPIKey]),
            .brainPreparation(.ready),
            .transcriptionPreparation(.ready),
            .transcriptionEndpoint(stream: .microphone, state: .ready),
            .transcriptionEndpoint(stream: .system, state: .ready),
            .capture(.ready),
        ], for: start.session).isEmpty)
        #expect(readiness.status == .blocked(.permissions([.screenRecording])))
    }

    @Test func credentialBrainAndTranscriptionFailuresStayTyped() {
        let credentials = JarvisReadiness()
        let credentialStart = credentials.begin(configuration: allRequirements)
        _ = credentials.observe(
            .permissions(granted: [.microphone, .screenRecording]),
            for: credentialStart.session)
        _ = credentials.observe(.credentials(available: []), for: credentialStart.session)
        #expect(credentials.status == .blocked(.credentials([.openAIAPIKey])))

        let brain = JarvisReadiness()
        let brainStart = brain.begin(configuration: .init())
        _ = brain.observe(
            .permissions(granted: [.microphone, .screenRecording]), for: brainStart.session)
        _ = brain.observe(
            .brainPreparation(.blocked(.providerUnavailable)), for: brainStart.session)
        #expect(brain.status == .blocked(.brain(.providerUnavailable)))

        let transcription = JarvisReadiness()
        let transcriptionStart = transcription.begin(
            configuration: .init(requiresTranscriptionPreparation: true))
        _ = transcription.observe(
            .permissions(granted: [.microphone, .screenRecording]),
            for: transcriptionStart.session)
        _ = transcription.observe(.brainPreparation(.ready), for: transcriptionStart.session)
        _ = transcription.observe(
            .transcriptionPreparation(.blocked(.preparationFailed)),
            for: transcriptionStart.session)
        #expect(transcription.status == .blocked(.transcription(.preparationFailed)))
    }

    @Test func microphoneFailureCannotBeResurrectedBeforeLifecycleStopArrives() {
        let (readiness, session) = fullReadyReadiness()
        _ = readiness.observe(
            .transcriptionEndpoint(stream: .microphone, state: .failed), for: session)
        #expect(readiness.status == .blocked(.endpoint(.microphone)))

        #expect(readiness.observe([
            .transcriptionEndpoint(stream: .microphone, state: .ready),
            .capture(.ready),
        ], for: session).isEmpty)
        #expect(readiness.status == .blocked(.endpoint(.microphone)))
    }

    @Test func stopAndNewStartRejectLateOrStaleObservations() {
        let (readiness, firstSession) = fullReadyReadiness()
        #expect(readiness.stop(session: firstSession) == [.statusChanged(.stopped)])
        #expect(readiness.observe(.capture(.ready), for: firstSession).isEmpty)
        #expect(readiness.status == .stopped)

        let second = readiness.begin(configuration: .init())
        #expect(readiness.status == .checking(.permissions))
        #expect(readiness.observe(
            .transcriptionEndpoint(stream: .microphone, state: .failed),
            for: firstSession).isEmpty)
        #expect(readiness.status == .checking(.permissions))

        _ = readiness.observe([
            .permissions(granted: [.microphone, .screenRecording]),
            .brainPreparation(.ready),
            .transcriptionEndpoint(stream: .microphone, state: .ready),
            .transcriptionEndpoint(stream: .system, state: .ready),
            .capture(.ready),
        ], for: second.session)
        #expect(readiness.status == .ready(.full))
    }

    private func fullReadyReadiness() -> (JarvisReadiness, JarvisReadiness.Session) {
        let readiness = JarvisReadiness()
        let start = readiness.begin(configuration: .init())
        _ = readiness.observe([
            .permissions(granted: [.microphone, .screenRecording]),
            .brainPreparation(.ready),
            .transcriptionEndpoint(stream: .microphone, state: .ready),
            .transcriptionEndpoint(stream: .system, state: .ready),
            .capture(.ready),
        ], for: start.session)
        #expect(readiness.status == .ready(.full))
        return (readiness, start.session)
    }
}
