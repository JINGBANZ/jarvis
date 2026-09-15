import Foundation
import Testing
@testable import JarvisCore

/// The runner reads every reply against the tool choice its own request sent, whatever the
/// transport did with that choice. A call outside a press's set, or a call whose arguments do not
/// parse, is answered and the model asked again in the same attempt; a press whose reply is prose
/// with no usable call speaks the prose; an extra parallel call is answered as not executed. Only
/// the forced response at the cap still fails the attempt, and the route retries.
@Suite struct CoachDriverReplyRecoveryTests {
    private func makeDriver(brain: BrainClient, screen: ScreenCapturing = FakeScreen(),
                            overlay: OverlayRendering = FakeOverlay())
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
            automaticAttemptDelay: { _ in })
        return (driver, transcript)
    }

    /// One attempt on the runner itself, where a failure is the attempt's own result rather than
    /// the start of the route's retries.
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

    /// A reply as a transport reports it: every call raw, and parsed where its arguments parse.
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

    /// #319: a press whose reply is only a call it may not make is told so, then speaks, all in one
    /// attempt, and the press never captures again.
    @Test(arguments: ["stay_silent", "capture_screen"])
    func aPressIsToldACallItMayNotMakeAndSpeaksInTheSameAttempt(_ name: String) async throws {
        let brain = ScriptedBrain(script: [reply(call(name, id: "q1")), speak])
        let screen = FakeScreen()
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: screen, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.calls.count == 2)
        #expect(screen.captureCount == 1)   // the press's own capture only
        let second = brain.calls[1]
        let answer = try #require(second.firstIndex { $0.role == .tool && $0.toolCallId == "q1" })
        #expect(second[answer].text == JarvisPrompts.Coach.notPermittedOnShortcut(name))
        #expect(second[answer - 1].toolCalls?.map(\.id) == ["q1"])
        #expect(overlay.rendered == [["Start from the read path."]])
    }

    /// Prose beside a call the press may not make is the hint: spoken with no extra round trip, and
    /// committed as a `speak` call with its own result so the next request replays a linked pair.
    @Test func aPressSpeaksTheProseBesideACallItMayNotMake() async throws {
        let brain = ScriptedBrain(script: [
            reply(call("stay_silent", id: "q1"), text: "Try a hash map.\n"),
            speak,
        ])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(brain.calls.count == 1)
        #expect(overlay.rendered == [["Try a hash map."]])

        transcript.append(.init(speaker: .them, text: "Walk me through the complexity.", at: 101))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let followUp = brain.calls[1]
        let replayed = try #require(followUp.first { $0.toolCalls?.first?.name == "speak" })
        let delivered = try #require(replayed.toolCalls?.first)
        let arguments = try #require(
            JSONSerialization.jsonObject(with: Data(delivered.argumentsJSON.utf8)) as? [String: Any])
        #expect(arguments["lines"] as? [String] == ["Try a hash map."])
        #expect(toolResult(delivered.id, in: followUp)?.text == JarvisPrompts.Coach.tipShown)
        #expect(!followUp.contains { $0.toolCalls?.contains { $0.name == "stay_silent" } == true })
    }

    @Test func aPressWhoseReplyIsOnlyProseSpeaksItsFirstThreeLines() async {
        let brain = ScriptedBrain(script: [
            reply(text: "Name the invariant.\n\n  Keep a running sum.  \nCheck the empty case.\nThen code it."),
        ])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(brain.calls.count == 1)
        #expect(overlay.rendered == [["Name the invariant.", "Keep a running sum.", "Check the empty case."]])
    }

    /// Only a press speaks prose: an automatic turn must choose to speak or stay silent.
    @Test func anAutomaticTurnWhoseReplyIsOnlyProseStillFails() async {
        let brain = ScriptedBrain(script: [reply(text: "Try a hash map.")])

        guard case .failed(let outcome, _, _) = await runAttempt(.turnEnd, brain: brain) else {
            Issue.record("expected prose alone to fail an automatic attempt"); return
        }
        #expect(outcome == .brainError)
        #expect(brain.calls.count == 1)
    }

    /// The double-encoded `lines` a Claude model sends without strict tools: answered with the
    /// schema, and the model's next call coaches in the same attempt.
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
        #expect(answer.text?.contains(speakTool.parametersJSON) == true)
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

    /// A provider that forces parallel calls can return two. The first runs; the second is answered
    /// so the replayed output never carries a call without a result.
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

    /// The parsed list skips a call whose arguments did not parse, so a valid later call must not
    /// stand in for the malformed first one: the first is answered with its schema and nothing runs.
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

    /// Recovery is bounded by the attempt's response cap, with no counter of its own.
    @Test func aPressThatNeverSpeaksFailsAtTheCap() async {
        let brain = ScriptedBrain(script: (1...7).map { reply(call("stay_silent", id: "q\($0)")) })

        guard case .failed(let outcome, let failure, _) = await runAttempt(.manualHint, brain: brain) else {
            Issue.record("expected the response at the cap to fail the attempt"); return
        }
        #expect(outcome == .brainError)
        #expect(failure.message == "provider called stay_silent, which this response did not permit")
        #expect(brain.calls.count == 7)
    }

    /// Nothing follows the response at the cap, so prose beside a call that cannot run is the hint
    /// there instead of a failed attempt.
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
