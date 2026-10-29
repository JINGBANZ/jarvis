import Foundation
import Testing
@testable import JarvisCore

@Suite(.serialized) struct CoachDriverCoachingModeTests {
    private func makeDriver(
        brain: BrainClient,
        activity: (any ActivityEventRecording)? = nil
    ) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let target = BrainTarget(
            provider: .openAI,
            modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [
                ConfiguredBrainTarget(target: target, brain: brain),
            ]),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(),
            automaticAttemptDelay: { _ in },
            activity: activity)
        return (driver, transcript)
    }

    private static func userText(_ request: [ChatMessage]) -> String {
        request.compactMap(\.text).joined(separator: "\n")
    }

    @Test func manualModeSendsNothingOnTurnEndOrSilence() async {
        let brain = ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "s")])])
        let (driver, transcript) = makeDriver(brain: brain)
        driver.setMode(.manual)
        let boundary = transcript.append(.init(speaker: .them, text: "Design a URL shortener.", at: 1))

        #expect(await driver.handleTrigger(.turnEnd, transcriptBoundary: boundary) == .paused)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 40)) == .paused)
        #expect(brain.calls.isEmpty)
    }

    @Test func aManualPressSendsEverythingSpokenSinceTheLastSend() async throws {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "s", hint: "Start with the write path.")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain)
        driver.setMode(.manual)
        let question = transcript.append(.init(speaker: .them, text: "Design a URL shortener.", at: 1))
        #expect(await driver.handleTrigger(.turnEnd, transcriptBoundary: question) == .paused)
        let reply = transcript.append(.init(speaker: .me, text: "Let me clarify the scale first.", at: 5))
        #expect(await driver.handleTrigger(.turnEnd, transcriptBoundary: reply) == .paused)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.calls.count == 1)
        let text = Self.userText(try #require(brain.calls.first))
        #expect(text.contains("Design a URL shortener."))
        #expect(text.contains("Let me clarify the scale first."))
    }

    @Test func switchingToManualDropsAQueuedAutomaticTurn() async {
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, script: [
            .init(toolCalls: [.staySilent(callId: "first")]),
            .init(toolCalls: [.staySilent(callId: "second")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain)
        transcript.append(.init(speaker: .them, text: "Tell me about yourself.", at: 1))
        let inFlight = Task { await driver.handleTrigger(.turnEnd) }
        await gate.waitUntilEntered()

        let later = transcript.append(.init(speaker: .me, text: "Sure, I lead a platform team.", at: 4))
        #expect(await driver.handleTrigger(.turnEnd, transcriptBoundary: later) == .busy)
        driver.setMode(.manual)
        await gate.release()

        #expect(await inFlight.value == .silentByModel)
        #expect(brain.callCount == 1)
    }

    @Test func switchingToManualStopsAnAutomaticRetry() async {
        let gate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let (driver, transcript) = makeDriver(brain: brain)
        transcript.append(.init(speaker: .them, text: "What's the time complexity?", at: 1))
        let inFlight = Task { await driver.handleTrigger(.turnEnd) }
        await gate.waitUntilEntered()

        driver.setMode(.manual)
        await gate.release()

        #expect(await inFlight.value == .paused)
        #expect(brain.calls.count == 1)
    }

    @Test func aManualPressDuringAPausedRetryStillGetsItsTip() async throws {
        let gate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let (driver, transcript) = makeDriver(brain: brain)
        transcript.append(.init(speaker: .them, text: "What's the time complexity?", at: 1))
        let inFlight = Task { await driver.handleTrigger(.turnEnd) }
        await gate.waitUntilEntered()

        driver.setMode(.manual)
        #expect(await driver.handleTrigger(.manualHint) == .busy)
        await gate.release()

        #expect(await inFlight.value == .spoke)
        #expect(brain.calls.count == 2)
        #expect(Self.userText(try #require(brain.calls.last)).contains("hint shortcut"))
    }

    @Test func returningToAutomaticCarriesSpeechHeardInManualMode() async throws {
        let brain = ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "s")])])
        let (driver, transcript) = makeDriver(brain: brain)
        driver.setMode(.manual)
        let heard = transcript.append(.init(speaker: .them, text: "Walk me through your design.", at: 1))
        #expect(await driver.handleTrigger(.turnEnd, transcriptBoundary: heard) == .paused)

        driver.setMode(.automatic)
        let next = transcript.append(.init(speaker: .me, text: "I'd start with the API.", at: 6))
        #expect(await driver.handleTrigger(.turnEnd, transcriptBoundary: next) == .silentByModel)

        #expect(brain.calls.count == 1)
        let text = Self.userText(try #require(brain.calls.first))
        #expect(text.contains("Walk me through your design."))
        #expect(text.contains("I'd start with the API."))
    }

    @Test func activityRecordsEachRealModeChange() {
        let activity = RecordingActivity()
        let (driver, _) = makeDriver(
            brain: ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "s")])]),
            activity: activity)

        driver.setMode(.automatic)
        driver.setMode(.manual)
        driver.setMode(.manual)
        driver.setMode(.automatic)

        #expect(activity.kinds == [.coachingModeChanged, .coachingModeChanged])
        let messages = activity.events.map(\.rendered.message)
        #expect(messages[0].contains("manual mode"))
        #expect(messages[1].contains("automatic mode"))
        #expect(messages.allSatisfy { ActivityLog.isHumanFacing(message: $0, imageFile: nil, kind: .coachingModeChanged) })
    }

    @Test func toggledFlipsBetweenTheTwoModes() {
        #expect(CoachingMode.automatic.toggled == .manual)
        #expect(CoachingMode.manual.toggled == .automatic)
    }
}
