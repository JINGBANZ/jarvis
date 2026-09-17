import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachDriverReplyRecoveryTests {
    private func makeDriver(brain: BrainClient, screen: ScreenCapturing = FakeScreen(),
                            overlay: OverlayRendering = FakeOverlay(),
                            capabilities: CoachCapabilities = .default)
        -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let target = BrainTarget(
            provider: .openAI,
            modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [
                ConfiguredBrainTarget(target: target, brain: brain),
            ]),
            screen: screen, overlay: overlay, clock: ManualClock(now: 100),
            automaticAttemptDelay: { _ in },
            capabilities: capabilities)
        return (driver, transcript)
    }

    private func runAttempt(
        _ reason: TriggerReason, brain: BrainClient, overlay: FakeOverlay = FakeOverlay()
    ) async -> CoachAttemptRunner.AttemptResult {
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .them, text: "How would you find a duplicate?", at: 100))
        let runner = CoachAttemptRunner(
            config: .default, transcript: transcript, screen: FakeScreen(),
            overlay: overlay, clock: ManualClock(now: 100), sessionStart: 0,
            coachingAttempts: nil, activity: nil, ledger: CoachTranscriptLedger(),
            capabilities: .default)
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        return await runner.runAttempt(.init(reason: reason), using: .init(
            plan: .default, routeRevision: 0, routeTopologyRevision: 0, routeIndex: 0,
            target: target, brain: brain, summarizer: nil, onSelected: nil,
            prepMaterial: nil)).result
    }

    private func reply(_ calls: RawToolCall..., text: String? = nil) -> BrainResponse {
        BrainResponse(
            toolCalls: calls.compactMap {
                ToolInvocation.parse(callId: $0.id, name: $0.name, argumentsJSON: $0.argumentsJSON)
            },
            rawToolCalls: calls,
            outputText: text)
    }

    private func call(_ name: String, id: String, arguments: String = "{}") -> RawToolCall {
        RawToolCall(id: id, name: name, argumentsJSON: arguments)
    }

    private var speak: BrainResponse {
        reply(call("speak", id: "s1", arguments: #"{"lines":["Start from the read path."]}"#))
    }

    private func toolResult(_ id: String, in request: [ChatMessage]) -> ChatMessage? {
        request.first { $0.role == .tool && $0.toolCallId == id }
    }

    @Test(arguments: ["stay_silent", "capture_screen"])
    func aPressIsToldACallItMayNotMakeAndSpeaksInTheSameAttempt(_ name: String) async throws {
        let brain = ScriptedBrain(script: [reply(call(name, id: "q1")), speak])
        let screen = FakeScreen()
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: screen, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.calls.count == 2)
        #expect(screen.captureCount == 1)
        let second = brain.calls[1]
        let answer = try #require(second.firstIndex { $0.role == .tool && $0.toolCallId == "q1" })
        #expect(second[answer].text == JarvisPrompts.Coach.notPermittedOnShortcut(name))
        #expect(second[answer - 1].toolCalls?.map(\.id) == ["q1"])
        #expect(overlay.rendered == [["Start from the read path."]])
    }

    @Test func aPressWithProseBesideACallItMayNotMakeIsStillAskedAgain() async throws {
        let brain = ScriptedBrain(script: [
            reply(call("stay_silent", id: "q1"), text: "Try a hash map.\n"),
            speak,
        ])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(brain.calls.count == 2)
        #expect(overlay.rendered == [["Start from the read path."]])

        transcript.append(.init(speaker: .them, text: "Walk me through the complexity.", at: 101))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let followUp = brain.calls[2]
        let replayed = try #require(followUp.first { $0.toolCalls?.first?.name == "speak" })
        let delivered = try #require(replayed.toolCalls?.first)
        let arguments = try #require(
            JSONSerialization.jsonObject(with: Data(delivered.argumentsJSON.utf8)) as? [String: Any])
        #expect(arguments["lines"] as? [String] == ["Start from the read path."])
        #expect(toolResult(delivered.id, in: followUp)?.text == JarvisPrompts.Coach.tipShown())
        #expect(!followUp.contains { $0.toolCalls?.contains { $0.name == "stay_silent" } == true })
    }

    @Test func aRefusedStaySilentLeavesNoTraceInHistory() async throws {
        let brain = ScriptedBrain(script: [reply(call("stay_silent", id: "q1")), speak, speak])
        let (driver, transcript) = makeDriver(brain: brain)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        transcript.append(.init(speaker: .them, text: "Walk me through the complexity.", at: 101))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        #expect(brain.calls.count == 3)
        let followUp = try #require(brain.calls.last)
        #expect(followUp.contains { $0.toolCalls?.first?.name == "speak" })
        #expect(!followUp.contains { $0.toolCalls?.contains { $0.name == "stay_silent" } == true })
        #expect(toolResult("q1", in: followUp) == nil)
    }

    @Test func aPressWhoseReplyIsOnlyProseIsRefusedOnceAndAsksAgain() async throws {
        let brain = ScriptedBrain(script: [reply(text: "Name the invariant."), speak])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.calls.count == 2)
        let second = try #require(brain.calls.last)
        #expect(second.contains { $0.role == .assistant && $0.text == "Name the invariant." })
        #expect(second.contains {
            $0.role == .user && $0.text == JarvisPrompts.Coach.replyMustCallSpeak(detailEnabled: false)
        })
        #expect(overlay.rendered == [["Start from the read path."]])
    }

    @Test func aRefusedProseReplyLeavesNoTraceInHistory() async throws {
        let brain = ScriptedBrain(script: [reply(text: "Name the invariant."), speak, speak])
        let (driver, transcript) = makeDriver(brain: brain)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        transcript.append(.init(speaker: .them, text: "Walk me through the complexity.", at: 101))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let followUp = try #require(brain.calls.last)
        #expect(!followUp.contains { $0.text == "Name the invariant." })
        #expect(!followUp.contains {
            $0.text == JarvisPrompts.Coach.replyMustCallSpeak(detailEnabled: false)
        })
    }

    @Test func aSecondProseReplyBecomesTheHintAndItsDetail() async throws {
        let prose = "Name the invariant.\n\nKeep a running sum.\n\n```python\ntotal = 0\n```"
        let brain = ScriptedBrain(script: [reply(text: prose), reply(text: prose)])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, overlay: overlay,
                                     capabilities: CoachCapabilities.compose(
                                        disabledTools: [], prepSourcesConfigured: false,
                                        detailEnabled: true))

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(brain.calls.count == 2)
        #expect(overlay.rendered == [["Name the invariant."]])
    }

    @Test func anAutomaticTurnWhoseReplyIsOnlyProseStillFails() async {
        let brain = ScriptedBrain(script: [reply(text: "Try a hash map.")])

        guard case .failed(let outcome, _, _) = await runAttempt(.turnEnd, brain: brain) else {
            Issue.record("expected prose alone to fail an automatic attempt"); return
        }
        #expect(outcome == .brainError)
        #expect(brain.calls.count == 1)
    }

    /// Claude without strict tools can double-encode `lines` as a JSON string.
    @Test func aCallWhoseArgumentsDoNotParseIsAnsweredWithItsSchema() async throws {
        let brain = ScriptedBrain(script: [
            reply(call("speak", id: "m1", arguments: #"{"lines":"[\"a\"]"}"#)),
            speak,
        ])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.calls.count == 2)
        let answer = try #require(toolResult("m1", in: brain.calls[1]))
        #expect(answer.text?.contains("did not match its schema") == true)
        #expect(answer.text?.contains(speakTool(detailEnabled: false).parametersJSON) == true)
        #expect(overlay.rendered == [["Start from the read path."]])
    }

    @Test func aCallToAToolNobodyDeclaredIsAnsweredAndTheTurnContinues() async throws {
        let brain = ScriptedBrain(script: [reply(call("read_my_email", id: "u1")), speak])
        let (driver, transcript) = makeDriver(brain: brain)
        transcript.append(.init(speaker: .me, text: "what should I say here", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        #expect(toolResult("u1", in: brain.calls[1])?.text
            == JarvisPrompts.Coach.toolUnavailable("read_my_email"))
    }

    /// A provider that forces parallel calls can return two in one reply.
    @Test func anExtraParallelCallIsAnsweredAsNotExecuted() async throws {
        let brain = ScriptedBrain(script: [
            reply(call("capture_screen", id: "c1"),
                  call("speak", id: "s0", arguments: #"{"lines":["Too early."]}"#)),
            speak,
        ])
        let screen = FakeScreen()
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, screen: screen, overlay: overlay)
        transcript.append(.init(speaker: .them, text: "What does your code print?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        #expect(screen.captureCount == 1)
        let continuation = brain.calls[1]
        #expect(toolResult("c1", in: continuation) != nil)
        #expect(toolResult("s0", in: continuation)?.text == JarvisPrompts.Coach.extraCallNotExecuted)
        #expect(overlay.rendered == [["Start from the read path."]])
    }

    @Test func aMalformedFirstCallIsJudgedBeforeAParsedLaterOne() async throws {
        let brain = ScriptedBrain(script: [
            reply(call("speak", id: "m1", arguments: #"{"lines":"[\"a\"]"}"#),
                  call("stay_silent", id: "q2")),
            speak,
        ])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay)
        transcript.append(.init(speaker: .them, text: "What does your code print?", at: 100))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        #expect(brain.calls.count == 2)
        let continuation = brain.calls[1]
        #expect(toolResult("m1", in: continuation)?.text?.contains("did not match its schema") == true)
        #expect(toolResult("q2", in: continuation)?.text == JarvisPrompts.Coach.extraCallNotExecuted)
        #expect(overlay.rendered == [["Start from the read path."]])
    }

    @Test func aPressThatNeverSpeaksFailsAtTheCap() async {
        let brain = ScriptedBrain(script: (1...7).map { reply(call("stay_silent", id: "q\($0)")) })

        guard case .failed(let outcome, let failure, _) = await runAttempt(.manualHint, brain: brain) else {
            Issue.record("expected the response at the cap to fail the attempt"); return
        }
        #expect(outcome == .brainError)
        #expect(failure.message == "provider called stay_silent, which this response did not permit")
        #expect(brain.calls.count == 7)
    }

    @Test func aPressSpeaksTheProseBesideAMalformedCallAtTheCap() async {
        let silences = (1...6).map { reply(call("stay_silent", id: "q\($0)")) }
        let malformed = reply(call("speak", id: "m7", arguments: #"{"lines":"[\"a\"]"}"#),
                              text: "Try a hash map.")
        let brain = ScriptedBrain(script: silences + [malformed])
        let overlay = FakeOverlay()

        guard case .completed(let outcome) = await runAttempt(.manualHint, brain: brain, overlay: overlay)
        else {
            Issue.record("expected the prose to be spoken at the cap"); return
        }
        #expect(outcome == .spoke)
        #expect(brain.calls.count == 7)
        #expect(overlay.rendered == [["Try a hash map."]])
    }
}
