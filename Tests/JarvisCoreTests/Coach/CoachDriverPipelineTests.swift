import Foundation
import Testing
@testable import JarvisCore

/// Mock brain: replays a script of responses and records the messages + tool-choice + conversation.
/// `failConversation` makes createConversation throw, to exercise the stateless fallback.
final class ScriptedBrain: BrainClient, @unchecked Sendable {
    private(set) var calls: [[ChatMessage]] = []
    private(set) var toolChoices: [ToolChoice] = []
    private(set) var conversationIds: [String?] = []
    private(set) var createConversationCount = 0
    let script: [BrainResponse]
    let failConversation: Bool
    init(script: [BrainResponse], failConversation: Bool = false) {
        self.script = script; self.failConversation = failConversation
    }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice,
                 conversationId: String?) async throws -> BrainResponse {
        calls.append(messages)
        toolChoices.append(toolChoice)
        conversationIds.append(conversationId)
        return script[min(calls.count - 1, script.count - 1)]
    }
    func createConversation() async throws -> String {
        createConversationCount += 1
        if failConversation { throw NSError(domain: "test", code: 503) }
        return "conv_test"
    }
}

/// A brain whose per-call script can be a response OR a throw (nil), recording the messages it saw —
/// to verify a tool-result survives a failed/cancelled turn and is re-sent on the next.
final class ScriptedThrowBrain: BrainClient, @unchecked Sendable {
    private(set) var calls: [[ChatMessage]] = []
    private var idx = 0
    let script: [BrainResponse?]
    init(script: [BrainResponse?]) { self.script = script }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice,
                 conversationId: String?) async throws -> BrainResponse {
        calls.append(messages)
        let r = script[min(idx, script.count - 1)]; idx += 1
        guard let r else { throw NSError(domain: "test", code: 500) }
        return r
    }
}

final class FakeScreen: ScreenCapturing, @unchecked Sendable {
    var captureCount = 0
    let payload: String
    init(payload: String = "ZmFrZS1qcGVn") { self.payload = payload } // "fake-jpeg"
    func capture() -> String? { captureCount += 1; return payload }
}

final class FakeOverlay: OverlayRendering, @unchecked Sendable {
    /// One entry per `render` call: the lines the brain returned, passed straight through (no splitting).
    var rendered: [[String]] = []
    /// The per-line display times passed alongside each `render` call (length-scaled by the driver).
    var renderedSeconds: [[TimeInterval]] = []
    func render(_ lines: [String], perLineSeconds: [TimeInterval]) {
        rendered.append(lines)
        renderedSeconds.append(perLineSeconds)
    }
}

@Suite struct CoachDriverPipelineTests {
    private func makeDriver(brain: BrainClient, screen: ScreenCapturing, overlay: OverlayRendering,
                            clock: Clock) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            brain: brain, screen: screen, overlay: overlay, clock: clock
        )
        return (driver, transcript)
    }

    @Test func captureThenSpeakPipeline() async {
        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c1")],
                  rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.speak(callId: "s1", lines: ["What's the complexity of that nested loop?"])],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                             argumentsJSON: #"{"lines":["What's the complexity of that nested loop?"]}"#)]),
        ])
        let screen = FakeScreen()
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, screen: screen, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "I'll brute-force two-sum with a double loop", at: 100))

        await driver.handleTrigger(.turnEnd)

        #expect(screen.captureCount == 1)
        #expect(overlay.rendered == [["What's the complexity of that nested loop?"]])
        #expect(brain.calls.count == 2)
        // Second brain call must contain the screenshot image we fed back...
        #expect(brain.calls[1].contains { $0.imageBase64JPEG != nil })
        // ...and the tool-result message answering the capture_screen call. With a server-side
        // conversation the model's function_call lives in the conversation, so it is NOT replayed.
        #expect(brain.calls[1].contains { $0.role == .tool && $0.toolCallId == "c1" })
        #expect(!brain.calls[1].contains { $0.role == .assistant && $0.toolCalls != nil })
    }

    /// End-to-end: a real capture→speak turn through the production `CoachDriver` with the activity
    /// log enabled (as dev mode does). Proves the screenshot the model looked at lands in the
    /// activity log as a genuine, owner-only JPEG rendered as a clickable thumbnail linked to the
    /// full image — the behaviour verified by hand, now automated against regressions.
    ///
    /// This drives the shared `ActivityLog` singleton (the real production path: CoachDriver → jlog →
    /// ActivityLog.shared). Peer tests in this suite also call jlog() and can write into this dir
    /// while it's the active sink — `.serialized` does NOT prevent that (swift-testing's serialization
    /// doesn't isolate a test from its peers). Robustness instead comes from: (1) selecting the shot
    /// by exact byte-match to our fixture, so another test's screenshot can't be mistaken for ours,
    /// and (2) the append-only `jarvis-activity.jsonl`, so our line survives interleaved writes.
    /// `disable()` in defer resets the singleton afterwards.
    @Test func screenshotLandsInActivityLogAsValidJpeg() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-e2e-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { ActivityLog.shared.disable(); try? FileManager.default.removeItem(at: dir) }
        ActivityLog.shared.enable(directory: dir)

        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c1")],
                  rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.speak(callId: "s1", lines: ["Watch the off-by-one there."])],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                             argumentsJSON: #"{"lines":["Watch the off-by-one there."]}"#)]),
        ])
        let screen = FakeScreen(payload: TestFixtures.tinyJpegBase64)   // a real JPEG, like screencapture
        let (driver, transcript) = makeDriver(brain: brain, screen: screen, overlay: FakeOverlay(), clock: clock)
        transcript.append(.init(speaker: .me, text: "here's my solution", at: 100))

        await driver.handleTrigger(.turnEnd)

        // attach() runs on the activity log's serial queue (a sync barrier after the async record()
        // calls), so everything is persisted before we assert.
        _ = ActivityLog.shared.attach { _ in }
        let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        #expect(jsonl.contains("looking at your screen"))   // the capture line
        #expect(jsonl.contains("shot-"))                     // line references the saved screenshot

        // Find OUR screenshot by exact byte-match to the fixture (not just "first valid JPEG"), so a
        // peer test sharing the singleton can't be mistaken for ours. This proves the capture
        // round-tripped to disk unchanged. Then assert it's owner-only.
        let shots = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("shot-") && $0.pathExtension == "jpg" }
        let shot = try #require(try shots.first { try Data(contentsOf: $0) == TestFixtures.tinyJpeg },
                                "expected our screenshot (byte-exact) in the activity log dir")
        // Sanity: the matched bytes really are a JPEG (SOI/EOI markers intact).
        let bytes = try Data(contentsOf: shot)
        #expect(bytes.prefix(2) == Data([0xFF, 0xD8]) && bytes.suffix(2) == Data([0xFF, 0xD9]))
        let perms = try FileManager.default.attributesOfItem(atPath: shot.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    /// A `speak` with an empty `lines` array (the decode fallback, or a model returning []) is passed
    /// straight through: the real overlay no-ops on it, but the turn still reports `.spoke` and closes
    /// the tool call. Pin this so the empty-speak contract stays intentional, not incidental.
    @Test func emptySpeakLinesStillReportsSpoke() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: [])])])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: overlay, clock: clock)
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(overlay.rendered == [[]])
    }

    @Test func staySilentRendersNothing() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: overlay, clock: clock)
        await driver.handleTrigger(.turnEnd)
        #expect(overlay.rendered.isEmpty)
    }

    // MARK: - Server-side conversation state (Workstream G)

    /// One conversation is created per session and reused across triggers (consistent id).
    @Test func createsConversationOnceAndThreadsId() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["hi"])])])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        await driver.handleTrigger(.turnEnd)
        await driver.handleTrigger(.turnEnd)
        #expect(brain.createConversationCount == 1)               // created once for the session
        #expect(brain.conversationIds == ["conv_test", "conv_test"]) // reused on every call
    }

    // MARK: - Conversation-state rework regressions (review must-fixes)

    /// A capture_screen on the FINAL tool iteration (loop cap) must not be left dangling: its tool
    /// result is closed on the next turn, or the conversation 400s forever.
    @Test func captureOnFinalIterationIsClosedNextTurn() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "cap")],
                  rawToolCalls: [RawToolCall(id: "cap", name: "capture_screen", argumentsJSON: "{}")]),
        ])  // repeats capture every iteration → turn 1 exhausts with an unanswered capture
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        #expect(await driver.handleTrigger(.turnEnd) == .exhausted)
        let afterTurn1 = brain.calls.count
        await driver.handleTrigger(.turnEnd)
        // The follow-up turn's FIRST request must close the dangling capture.
        #expect(brain.calls[afterTurn1].contains { $0.role == .tool && $0.toolCallId == "cap" })
    }

    /// A prior speak's tool-result must NOT be lost if the very next turn fails before sending — it
    /// stays pending and is carried on the turn after.
    @Test func speakCallRetainedWhenNextTurnFails() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedThrowBrain(script: [
            .init(toolCalls: [.speak(callId: "spk1", lines: ["hi"])]),   // turn 1: speak → stash spk1
            nil,                                                        // turn 2: throws before sending
            .init(toolCalls: []),                                       // turn 3: silent
        ])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        await driver.handleTrigger(.turnEnd)
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        await driver.handleTrigger(.turnEnd)
        #expect(brain.calls.last!.contains { $0.role == .tool && $0.toolCallId == "spk1" })
    }

    /// When the conversation can't be created, turns run statelessly — and must still carry a CONTEXT
    /// WINDOW (not just the per-turn delta), or the model loses the problem statement.
    @Test func statelessTurnCarriesContextWindowAndSpeaks() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["hi"])])],
                                  failConversation: true)
        let (driver, transcript) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        transcript.append(.init(speaker: .me, text: "the whole problem context", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(brain.conversationIds.last! == nil)           // ran stateless
        transcript.append(.init(speaker: .me, text: "new utterance", at: 5))
        await driver.handleTrigger(.turnEnd)
        let lastUser = brain.calls.last!.compactMap { $0.text }.joined(separator: " ")
        #expect(lastUser.contains("the whole problem context"))   // window keeps prior context
        #expect(lastUser.contains("new utterance"))
        #expect(brain.createConversationCount == 1)               // failure flag prevents re-POST every turn
    }

    // MARK: - Observability: structured turn outcomes (Workstream B)

    @Test func spokeOutcome() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", lines: ["hi"])])])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
    }

    @Test func silentByModelOutcomeWhenNoToolCalls() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
    }

    /// No cooldown: two back-to-back turns both reach the brain and both speak (the inverse of the
    /// old rate-cap behavior, which suppressed the second).
    @Test func consecutiveTurnsBothReachBrain() async {
        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", lines: ["first"])])])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: overlay, clock: clock)
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)   // immediately again — not held back
        #expect(brain.calls.count == 2)
        #expect(overlay.rendered.count == 2)
    }

    /// A token-truncated response (zero tool calls but status=incomplete) must be reported as
    /// `.truncated`, NOT mistaken for deliberate `.silentByModel`, and must render nothing.
    @Test func truncatedOutcomeWhenResponseIncomplete() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [], rawToolCalls: [],
                                                 incompleteReason: "max_output_tokens")])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: overlay, clock: clock)
        #expect(await driver.handleTrigger(.turnEnd) == .truncated)
        #expect(overlay.rendered.isEmpty)
    }

    /// A model that loops on capture_screen forever hits the iteration cap and reports `.exhausted`.
    @Test func exhaustedOutcomeWhenModelLoopsOnCapture() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c")],
                  rawToolCalls: [RawToolCall(id: "c", name: "capture_screen", argumentsJSON: "{}")]),
        ])  // ScriptedBrain repeats the last response, so every iteration captures again
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: overlay, clock: clock)
        #expect(await driver.handleTrigger(.turnEnd) == .exhausted)
        #expect(overlay.rendered.isEmpty)
    }

    @Test func brainErrorOutcome() async {
        let clock = ManualClock(now: 0)
        let brain = ThrowingBrain()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
    }

    /// No forcing: every turn uses tool_choice auto so the model picks the right tool from the
    /// prompt — reply, look at the screen, or stay silent.
    @Test func everyTurnUsesAutoToolChoice() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", lines: ["hi"])])])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        await driver.handleTrigger(.turnEnd)
        #expect(brain.toolChoices.last == .auto)
    }

    /// A `speak` call is closed lazily on the NEXT turn: its tool-result is prepended to the next
    /// request (bundled with the new speech), so the server-side conversation never dangles.
    @Test func nextTurnAnswersPriorSpeak() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "spk1", lines: ["hi"])])])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        await driver.handleTrigger(.turnEnd)          // speaks, stashes spk1 to close next turn
        await driver.handleTrigger(.turnEnd)
        // The second request must include the tool-result that closes spk1.
        #expect(brain.calls[1].contains { $0.role == .tool && $0.toolCallId == "spk1" })
    }

    /// Index-based delta in the PRODUCTION time domain (lines stamped session-relative): turn 1 must
    /// carry the user's actual words; turn 2 carries only the NEW words, not the old ones.
    @Test func indexDeltaSendsOnlyNewLinesAcrossTurns() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])   // stays silent → one call per turn
        let (driver, transcript) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        transcript.append(.init(speaker: .me, text: "two sum brute force", at: 1))
        await driver.handleTrigger(.turnEnd)
        #expect(brain.calls[0].contains { ($0.text ?? "").contains("two sum brute force") })

        transcript.append(.init(speaker: .me, text: "maybe a hash map", at: 5))
        await driver.handleTrigger(.turnEnd)
        let secondUserText = brain.calls[1].compactMap { $0.text }.joined(separator: " ")
        #expect(secondUserText.contains("maybe a hash map"))
        #expect(!secondUserText.contains("two sum brute force"))   // already sent last turn
    }

    /// Speech is NOT marked sent on a failed turn — it is re-sent next turn (advance-on-success).
    @Test func unsentSpeechResentAfterBrainError() async {
        let clock = ManualClock(now: 0)
        let brain = FlakyBrain(throwsOnFirst: true)
        let (driver, transcript) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        transcript.append(.init(speaker: .me, text: "important words", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)   // first call throws, not sent
        await driver.handleTrigger(.turnEnd)
        #expect(brain.lastMessages.contains { ($0.text ?? "").contains("important words") })   // re-sent
    }

    /// While one turn is in flight, a second concurrent trigger must be reported as `.busy` AND
    /// coalesced: the running turn picks it up and runs it too, so nothing is dropped (vs. the old
    /// cancel-the-previous behavior).
    @Test func concurrentTriggerIsBusyThenCoalesced() async {
        let clock = ManualClock(now: 0)
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, response: .init(toolCalls: [.speak(callId: "s1", lines: ["hi"])]))
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        async let first = driver.handleTrigger(.turnEnd)   // parks in the brain call, holds the slot
        await gate.waitUntilEntered()
        let second = await driver.handleTrigger(.turnEnd)  // busy → queued as pending
        #expect(second == .busy)
        await gate.release()
        _ = await first
        #expect(brain.callCount >= 2)                      // the original AND the coalesced turn ran
    }
}

/// A brain that throws on its first call then succeeds (silent), recording the last messages it saw —
/// to verify speech un-sent on a failed turn is re-sent on the next.
final class FlakyBrain: BrainClient, @unchecked Sendable {
    private var calls = 0
    private let throwsOnFirst: Bool
    private(set) var lastMessages: [ChatMessage] = []
    init(throwsOnFirst: Bool) { self.throwsOnFirst = throwsOnFirst }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice,
                 conversationId: String?) async throws -> BrainResponse {
        calls += 1
        lastMessages = messages
        if throwsOnFirst && calls == 1 { throw NSError(domain: "test", code: 500) }
        return .init(toolCalls: [])
    }
}

/// A brain that always throws, to exercise the `.brainError` outcome.
final class ThrowingBrain: BrainClient, @unchecked Sendable {
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice,
                 conversationId: String?) async throws -> BrainResponse {
        throw NSError(domain: "test", code: 401)
    }
}

/// A brain that parks inside `respond` until released, so a second concurrent trigger can be
/// observed hitting the single-in-flight guard.
final class GatedBrain: BrainClient, @unchecked Sendable {
    private let gate: AsyncGate
    private let response: BrainResponse
    private let lock = NSLock()
    private var _callCount = 0
    private var _lastMessages: [ChatMessage] = []
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    var lastMessages: [ChatMessage] { lock.lock(); defer { lock.unlock() }; return _lastMessages }
    private func record(_ m: [ChatMessage]) { lock.lock(); _callCount += 1; _lastMessages = m; lock.unlock() }
    init(gate: AsyncGate, response: BrainResponse) { self.gate = gate; self.response = response }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice,
                 conversationId: String?) async throws -> BrainResponse {
        record(messages)
        await gate.enter()
        return response
    }
}

/// A one-shot async gate: the parked task signals it entered, then awaits release.
actor AsyncGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
