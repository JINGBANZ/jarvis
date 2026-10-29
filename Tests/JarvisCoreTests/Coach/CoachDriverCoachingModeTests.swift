import Foundation
import Testing
@testable import JarvisCore

@Suite(.serialized) struct CoachDriverCoachingModeTests {
    private func makeDriver(
        brain: BrainClient,
        activity: (any ActivityEventRecording)? = nil,
        clock: ManualClock = ManualClock(),
        manualSettlementGrace: Duration = .zero,
        automaticAttemptDelay: @escaping CoachDriver.AutomaticAttemptDelay = { _ in }
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
            screen: FakeScreen(), overlay: FakeOverlay(), clock: clock,
            automaticAttemptDelay: automaticAttemptDelay,
            manualSettlementGrace: manualSettlementGrace,
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

    @Test func aManualModePressWaitsForSpeechAlreadyInProgress() async throws {
        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", hint: "Ask about read volume.")])])
        let (driver, transcript) = makeDriver(
            brain: brain, clock: clock, manualSettlementGrace: .seconds(60))
        driver.setMode(.manual)
        transcript.append(.init(speaker: .them, text: "Design a URL shortener.", at: 1))
        driver.updateTranscriptionWork(.pending(since: 2), for: .them)
        clock.advance(by: 3)

        let press = Task { await driver.handleTrigger(.manualHint) }
        #expect(!(await eventually { brain.calls.count == 1 }), "the press must wait for the utterance in progress")
        transcript.append(.init(speaker: .them, text: "It should handle a billion links.", at: 2))
        driver.updateTranscriptionWork(.settled, for: .them)

        #expect(await press.value == .spoke)
        #expect(Self.userText(try #require(brain.calls.first)).contains("It should handle a billion links."))
    }

    @Test func aManualModePressStopsWaitingAfterTheGrace() async {
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", hint: "Start with the API.")])])
        let (driver, _) = makeDriver(brain: brain, clock: ManualClock(now: 100))
        driver.setMode(.manual)
        driver.updateTranscriptionWork(.pending(since: nil), for: .them)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(brain.calls.count == 1)
    }

    @Test func speechStartedAfterAManualModePressDoesNotHoldItBack() async {
        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", hint: "Start with the API.")])])
        let (driver, _) = makeDriver(
            brain: brain, clock: clock, manualSettlementGrace: .seconds(60))
        driver.setMode(.manual)
        clock.advance(by: 3)
        driver.updateTranscriptionWork(.pending(since: 5), for: .me)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
    }

    @Test func anAutomaticModePressStillSendsAtOnce() async {
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", hint: "Start with the API.")])])
        let (driver, _) = makeDriver(
            brain: brain, clock: ManualClock(now: 100),
            manualSettlementGrace: .seconds(60))
        driver.updateTranscriptionWork(.pending(since: nil), for: .them)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
    }

    // MARK: - Every shortcut path waits for speech already in progress

    @Test func aPressQueuedBehindARunningAnswerWaitsForSpeechInProgress() async throws {
        let clock = ManualClock(now: 100)
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, script: [
            .init(toolCalls: [.speak(callId: "first", hint: "Clarify the read path.")]),
            .init(toolCalls: [.speak(callId: "second", hint: "Batch the writes.")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock, manualSettlementGrace: .seconds(60))
        driver.setMode(.manual)
        let running = Task { await driver.handleTrigger(.manualHint) }
        await gate.waitUntilEntered()

        driver.updateTranscriptionWork(.pending(since: 2), for: .them)
        clock.advance(by: 3)
        #expect(await driver.handleTrigger(.manualHint) == .busy)
        await gate.release()
        #expect(!(await eventually { brain.callCount == 2 }), "the queued press must wait")
        transcript.append(.init(speaker: .them, text: "And what about writes?", at: 2))
        driver.updateTranscriptionWork(.settled, for: .them)

        #expect(await running.value == .spoke)
        #expect(brain.callCount == 2)
        #expect(Self.userText(brain.calls[1]).contains("And what about writes?"))
    }

    @Test func aQueuedPressIsNotHeldBackBySpeechThatStartsAfterIt() async {
        let clock = ManualClock(now: 100)
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, script: [
            .init(toolCalls: [.speak(callId: "first", hint: "Clarify the read path.")]),
            .init(toolCalls: [.speak(callId: "second", hint: "Batch the writes.")]),
        ])
        let (driver, _) = makeDriver(brain: brain, clock: clock, manualSettlementGrace: .seconds(60))
        driver.setMode(.manual)
        let running = Task { await driver.handleTrigger(.manualHint) }
        await gate.waitUntilEntered()

        clock.advance(by: 3)
        #expect(await driver.handleTrigger(.manualHint) == .busy)
        driver.updateTranscriptionWork(.pending(since: 5), for: .them)
        await gate.release()

        #expect(await running.value == .spoke)
        #expect(brain.callCount == 2)
    }

    @Test func aPressDuringAPendingRetryWaitsForSpeechInProgress() async throws {
        let clock = ManualClock(now: 100)
        let gate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let (driver, transcript) = makeDriver(
            brain: brain, clock: clock, manualSettlementGrace: .seconds(60),
            automaticAttemptDelay: { _ in try await Task.sleep(for: .seconds(60)) })
        driver.setMode(.manual)
        let failing = Task { await driver.handleTrigger(.manualHint) }
        await gate.waitUntilEntered()

        driver.updateTranscriptionWork(.pending(since: 2), for: .them)
        clock.advance(by: 3)
        await gate.release()
        #expect(await driver.handleTrigger(.manualHint) == .busy)
        #expect(!(await eventually { brain.calls.count == 2 }), "the press must wait before the retry")
        transcript.append(.init(speaker: .them, text: "What's the time complexity?", at: 2))
        driver.updateTranscriptionWork(.settled, for: .them)

        #expect(await failing.value == .spoke)
        #expect(Self.userText(try #require(brain.calls.last)).contains("What's the time complexity?"))
    }

    @Test func aSecondPressDoesNotCutTheFirstPressesWaitShort() async throws {
        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", hint: "Ask about scale.")])])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock, manualSettlementGrace: .seconds(60))
        driver.setMode(.manual)
        driver.updateTranscriptionWork(.pending(since: 2), for: .them)
        clock.advance(by: 3)
        let first = Task { await driver.handleTrigger(.manualHint) }
        #expect(!(await eventually { brain.calls.count == 1 }))

        clock.advance(by: 2)
        #expect(await driver.handleTrigger(.manualHint) == .busy)
        #expect(!(await eventually { brain.calls.count == 1 }), "the second press must not end the wait")
        transcript.append(.init(speaker: .them, text: "Assume ten million users.", at: 2))
        driver.updateTranscriptionWork(.settled, for: .them)

        #expect(await first.value == .spoke)
        #expect(brain.calls.count == 1)
        #expect(Self.userText(try #require(brain.calls.first)).contains("Assume ten million users."))
    }

    // MARK: - Shortcuts keep their retry budget

    @Test func aShortcutRetriesATemporaryFailureInManualMode() async {
        let gate = AsyncGate()
        await gate.release()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let (driver, _) = makeDriver(brain: brain)
        driver.setMode(.manual)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(brain.calls.count == 2)
    }

    @Test func aShortcutAdvancesToTheFallbackInManualMode() async {
        let primary = ThrowingBrain()
        let fallback = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", hint: "fallback tip")])])
        let driver = CoachDriver(
            config: .default, transcript: RollingTranscript(),
            route: ConfiguredBrainRoute(targets: [
                ConfiguredBrainTarget(target: BrainTarget(provider: .openAI, modelID: "gpt-5.5"), brain: primary),
                ConfiguredBrainTarget(
                    target: BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5-5"),
                    brain: fallback),
            ]),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(),
            automaticAttemptDelay: { _ in })
        driver.setMode(.manual)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(primary.callCount == 3)
        #expect(fallback.calls.count == 1)
    }

    @Test func toggledFlipsBetweenTheTwoModes() {
        #expect(CoachingMode.automatic.toggled == .manual)
        #expect(CoachingMode.manual.toggled == .automatic)
    }
}

private func eventually(
    timeoutNanoseconds: UInt64 = 200_000_000,
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - startedAt < timeoutNanoseconds {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}
