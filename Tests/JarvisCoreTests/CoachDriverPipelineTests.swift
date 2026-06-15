import Foundation
import Testing
@testable import JarvisCore

/// Mock brain: replays a script of responses and records the messages + tool-choice + conversation.
final class ScriptedBrain: BrainClient, @unchecked Sendable {
    private(set) var calls: [[ChatMessage]] = []
    private(set) var toolChoices: [ToolChoice] = []
    private(set) var conversationIds: [String?] = []
    private(set) var createConversationCount = 0
    let script: [BrainResponse]
    init(script: [BrainResponse]) { self.script = script }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice,
                 conversationId: String?) async throws -> BrainResponse {
        calls.append(messages)
        toolChoices.append(toolChoice)
        conversationIds.append(conversationId)
        return script[min(calls.count - 1, script.count - 1)]
    }
    func createConversation() async throws -> String {
        createConversationCount += 1
        return "conv_test"
    }
}

final class FakeScreen: ScreenCapturing, @unchecked Sendable {
    var captureCount = 0
    let payload: String
    init(payload: String = "ZmFrZS1qcGVn") { self.payload = payload } // "fake-jpeg"
    func capture() -> String? { captureCount += 1; return payload }
}

final class FakeOverlay: OverlayRendering, @unchecked Sendable {
    var rendered: [String] = []
    func render(_ text: String, maxSentences: Int, perSentenceSeconds: TimeInterval) {
        rendered.append(text)
    }
}

@Suite struct CoachDriverPipelineTests {
    private func makeDriver(brain: BrainClient, screen: ScreenCapturing, overlay: OverlayRendering,
                            clock: Clock, guardrails: Guardrails) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default, transcript: transcript, guardrails: guardrails,
            brain: brain, screen: screen, overlay: overlay, clock: clock
        )
        return (driver, transcript)
    }

    @Test func captureThenSpeakPipeline() async {
        let clock = ManualClock(now: 100)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c1")],
                  rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.speak(callId: "s1", text: "What's the complexity of that nested loop?")],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                             argumentsJSON: #"{"text":"What's the complexity of that nested loop?"}"#)]),
        ])
        let screen = FakeScreen()
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, screen: screen, overlay: overlay,
                                              clock: clock, guardrails: guardrails)
        transcript.append(.init(speaker: .me, text: "I'll brute-force two-sum with a double loop", at: 100))

        await driver.handleTrigger(.turnEnd)

        #expect(screen.captureCount == 1)
        #expect(overlay.rendered == ["What's the complexity of that nested loop?"])
        #expect(brain.calls.count == 2)
        // Second brain call must contain the screenshot image we fed back...
        #expect(brain.calls[1].contains { $0.imageBase64JPEG != nil })
        // ...and the tool-result message answering the capture_screen call. With a server-side
        // conversation the model's function_call lives in the conversation, so it is NOT replayed.
        #expect(brain.calls[1].contains { $0.role == .tool && $0.toolCallId == "c1" })
        #expect(!brain.calls[1].contains { $0.role == .assistant && $0.toolCalls != nil })
    }

    @Test func staySilentRendersNothing() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: overlay,
                                     clock: clock, guardrails: guardrails)
        await driver.handleTrigger(.turnEnd)
        #expect(overlay.rendered.isEmpty)
    }

    @Test func muteSuppressesPipeline() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        guardrails.setMuted(true)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", text: "hi")])])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: overlay,
                                     clock: clock, guardrails: guardrails)
        await driver.handleTrigger(.turnEnd)
        #expect(overlay.rendered.isEmpty)
    }

    // MARK: - Server-side conversation state (Workstream G)

    /// One conversation is created per session and reused across triggers (consistent id).
    @Test func createsConversationOnceAndThreadsId() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 0, maxInterjectionsPerMinute: 99, clock: clock)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", text: "hi")])])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(),
                                     clock: clock, guardrails: guardrails)
        await driver.handleTrigger(.turnEnd)
        await driver.handleTrigger(.turnEnd)
        #expect(brain.createConversationCount == 1)               // created once for the session
        #expect(brain.conversationIds == ["conv_test", "conv_test"]) // reused on every call
    }

    // MARK: - Observability: structured turn outcomes (Workstream B)

    @Test func spokeOutcome() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", text: "hi")])])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(),
                                     clock: clock, guardrails: guardrails)
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
    }

    @Test func silentByModelOutcomeWhenNoToolCalls() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(),
                                     clock: clock, guardrails: guardrails)
        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
    }

    /// A token-truncated response (zero tool calls but status=incomplete) must be reported as
    /// `.truncated`, NOT mistaken for deliberate `.silentByModel`.
    @Test func truncatedOutcomeWhenResponseIncomplete() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ScriptedBrain(script: [.init(toolCalls: [], rawToolCalls: [],
                                                 incompleteReason: "max_output_tokens")])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(),
                                     clock: clock, guardrails: guardrails)
        #expect(await driver.handleTrigger(.turnEnd) == .truncated)
    }

    @Test func heldBackOutcomeDuringCooldown() async {
        let clock = ManualClock(now: 100)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", text: "first")])])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(),
                                     clock: clock, guardrails: guardrails)
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)   // starts the cooldown
        #expect(await driver.handleTrigger(.turnEnd) == .heldBack) // within 12s → blocked
    }

    /// A model that loops on capture_screen forever hits the iteration cap and reports `.exhausted`.
    @Test func exhaustedOutcomeWhenModelLoopsOnCapture() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c")],
                  rawToolCalls: [RawToolCall(id: "c", name: "capture_screen", argumentsJSON: "{}")]),
        ])  // ScriptedBrain repeats the last response, so every iteration captures again
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: overlay,
                                     clock: clock, guardrails: guardrails)
        #expect(await driver.handleTrigger(.turnEnd) == .exhausted)
        #expect(overlay.rendered.isEmpty)
    }

    @Test func brainErrorOutcome() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ThrowingBrain()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(),
                                     clock: clock, guardrails: guardrails)
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
    }

    // MARK: - Direct address (Workstream A)

    /// A direct address must reach the user even within the cooldown window.
    @Test func directAddressBypassesCooldown() async {
        let clock = ManualClock(now: 100)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", text: "hi there")])])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: overlay,
                                     clock: clock, guardrails: guardrails)
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)          // starts the cooldown
        #expect(await driver.handleTrigger(.directAddress) == .spoke)     // bypasses it
        #expect(overlay.rendered.count == 2)
    }

    /// Direct address still honors an explicit mute.
    @Test func directAddressHonorsMute() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        guardrails.setMuted(true)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", text: "hi")])])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: overlay,
                                     clock: clock, guardrails: guardrails)
        #expect(await driver.handleTrigger(.directAddress) == .heldBack)
        #expect(overlay.rendered.isEmpty)
    }

    /// No forcing: every turn (direct address included) uses tool_choice auto so the model picks the
    /// right tool from the prompt — e.g. capture_screen on "Jarvis, check my screen".
    @Test func everyTurnUsesAutoToolChoice() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", text: "hi")])])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(),
                                     clock: clock, guardrails: guardrails)
        await driver.handleTrigger(.directAddress)
        #expect(brain.toolChoices.last == .auto)
    }

    /// A `speak` call is closed lazily on the NEXT turn: its tool-result is prepended to the next
    /// request (bundled with the new speech), so the server-side conversation never dangles.
    @Test func nextTurnAnswersPriorSpeak() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 0, maxInterjectionsPerMinute: 99, clock: clock)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "spk1", text: "hi")])])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(),
                                     clock: clock, guardrails: guardrails)
        await driver.handleTrigger(.turnEnd)          // speaks, stashes spk1 to close next turn
        await driver.handleTrigger(.turnEnd)
        // The second request must include the tool-result that closes spk1.
        #expect(brain.calls[1].contains { $0.role == .tool && $0.toolCallId == "spk1" })
    }

    /// Index-based delta in the PRODUCTION time domain (lines stamped session-relative): turn 1 must
    /// carry the user's actual words; turn 2 carries only the NEW words, not the old ones.
    @Test func indexDeltaSendsOnlyNewLinesAcrossTurns() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 0, maxInterjectionsPerMinute: 99, clock: clock)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])   // stays silent → one call per turn
        let (driver, transcript) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(),
                                              clock: clock, guardrails: guardrails)
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
        let guardrails = Guardrails(cooldownSeconds: 0, maxInterjectionsPerMinute: 99, clock: clock)
        let brain = FlakyBrain(throwsOnFirst: true)
        let (driver, transcript) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(),
                                              clock: clock, guardrails: guardrails)
        transcript.append(.init(speaker: .me, text: "important words", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)   // first call throws, not sent
        await driver.handleTrigger(.turnEnd)
        #expect(brain.lastMessages.contains { ($0.text ?? "").contains("important words") })   // re-sent
    }

    /// A direct address must NEVER be left unanswered: if the turn produces no spoken reply (e.g. it
    /// truncates), the driver renders a spoken fallback rather than going silent.
    @Test func directAddressTruncationFallsBackToSpoken() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ScriptedBrain(script: [.init(toolCalls: [], rawToolCalls: [], incompleteReason: "max_output_tokens")])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: overlay,
                                     clock: clock, guardrails: guardrails)
        #expect(await driver.handleTrigger(.directAddress) == .spokeFallback)
        #expect(overlay.rendered.count == 1)
        #expect(!overlay.rendered[0].isEmpty)
    }

    /// An AMBIENT truncated turn stays `.truncated` (no fallback chatter when not addressed).
    @Test func ambientTruncationDoesNotFallBack() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ScriptedBrain(script: [.init(toolCalls: [], rawToolCalls: [], incompleteReason: "max_output_tokens")])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: overlay,
                                     clock: clock, guardrails: guardrails)
        #expect(await driver.handleTrigger(.turnEnd) == .truncated)
        #expect(overlay.rendered.isEmpty)
    }

    /// While one turn is in flight, a second concurrent trigger must be reported as `.busy`
    /// (the single-in-flight drop is now observable, not silent).
    /// A trigger arriving while a turn runs is reported `.busy` AND coalesced: the running turn picks
    /// it up and runs it too, so nothing is dropped (vs. the old cancel-the-previous behavior).
    @Test func concurrentTriggerIsBusyThenCoalesced() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 0, maxInterjectionsPerMinute: 99, clock: clock)
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, response: .init(toolCalls: [.speak(callId: "s1", text: "hi")]))
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(),
                                     clock: clock, guardrails: guardrails)
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
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    private func bump() { lock.lock(); _callCount += 1; lock.unlock() }
    init(gate: AsyncGate, response: BrainResponse) { self.gate = gate; self.response = response }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice,
                 conversationId: String?) async throws -> BrainResponse {
        bump()
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
