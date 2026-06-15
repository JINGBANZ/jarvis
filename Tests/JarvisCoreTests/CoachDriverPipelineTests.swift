import Foundation
import Testing
@testable import JarvisCore

/// Mock brain: replays a script of responses and records the messages + tool-choice it saw.
final class ScriptedBrain: BrainClient, @unchecked Sendable {
    private(set) var calls: [[ChatMessage]] = []
    private(set) var toolChoices: [ToolChoice] = []
    let script: [BrainResponse]
    init(script: [BrainResponse]) { self.script = script }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        calls.append(messages)
        toolChoices.append(toolChoice)
        return script[min(calls.count - 1, script.count - 1)]
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
        // ...and the assistant tool-call turn that precedes the tool result (B3).
        #expect(brain.calls[1].contains { $0.role == .assistant && $0.toolCalls != nil })
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

    /// Direct address forces the speak tool; ambient triggers leave the choice on auto.
    @Test func directAddressForcesSpeakToolChoice() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", text: "hi")])])
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(),
                                     clock: clock, guardrails: guardrails)
        await driver.handleTrigger(.directAddress)
        #expect(brain.toolChoices.last == .force("speak"))

        let brain2 = ScriptedBrain(script: [.init(toolCalls: [])])
        let (driver2, _) = makeDriver(brain: brain2, screen: FakeScreen(), overlay: FakeOverlay(),
                                      clock: clock, guardrails: Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock))
        await driver2.handleTrigger(.turnEnd)
        #expect(brain2.toolChoices.last == .auto)
    }

    /// A direct address must NEVER be left unanswered: if the forced-speak turn truncates (zero
    /// tool calls), the driver renders a spoken fallback rather than going silent.
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
    @Test func busyOutcomeWhenTurnInFlight() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, response: .init(toolCalls: [.speak(callId: "s1", text: "hi")]))
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: FakeOverlay(),
                                     clock: clock, guardrails: guardrails)
        // First turn parks inside the brain call, holding the in-flight slot.
        async let first = driver.handleTrigger(.turnEnd)
        await gate.waitUntilEntered()
        // Second trigger arrives while the first is parked → must be reported busy.
        let second = await driver.handleTrigger(.turnEnd)
        #expect(second == .busy)
        await gate.release()
        #expect(await first == .spoke)
    }
}

@Suite struct TurnTaskBoxTests {
    /// The barge-in regression test: while T1 is parked in the brain call (holding the single
    /// in-flight slot), fresh speech arrives via run(cancelPrevious:true). The replacement turn MUST
    /// actually run (.spoke), not be dropped as .busy. Verifies the deterministic handoff.
    @Test func cancelPreviousLetsReplacementRun() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, response: .init(toolCalls: [.speak(callId: "s1", text: "hi")]))
        let transcript = RollingTranscript()
        let driver = CoachDriver(config: .default, transcript: transcript, guardrails: guardrails,
                                 brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        let outcomes = OutcomeBox()
        let box = TurnTaskBox()

        box.run(cancelPrevious: false) { await outcomes.set(.first, driver.handleTrigger(.turnEnd)) }
        await gate.waitUntilEntered()              // T1 is parked inside the brain call
        box.run(cancelPrevious: true) { await outcomes.set(.second, driver.handleTrigger(.directAddress)) }
        await gate.release()                       // let both unwind

        #expect(await outcomes.await(.second) == .spoke)   // replacement actually ran
        #expect(await outcomes.await(.first) == .cancelled) // predecessor was cancelled, didn't render
    }

    /// run(cancelPrevious:false) (a silence tick) must NOT cancel an in-flight turn.
    @Test func silenceDoesNotCancelInFlight() async {
        let clock = ManualClock(now: 0)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, response: .init(toolCalls: [.speak(callId: "s1", text: "hi")]))
        let transcript = RollingTranscript()
        let driver = CoachDriver(config: .default, transcript: transcript, guardrails: guardrails,
                                 brain: brain, screen: FakeScreen(), overlay: FakeOverlay(), clock: clock)
        let outcomes = OutcomeBox()
        let box = TurnTaskBox()
        box.run(cancelPrevious: false) { await outcomes.set(.first, driver.handleTrigger(.turnEnd)) }
        await gate.waitUntilEntered()
        box.run(cancelPrevious: false) { await outcomes.set(.second, driver.handleTrigger(.silence(secondsQuiet: 8)) ) }
        await gate.release()
        #expect(await outcomes.await(.first) == .spoke)   // first was NOT cancelled
    }
}

/// Records two turn outcomes and lets a test await whichever it needs.
actor OutcomeBox {
    enum Slot { case first, second }
    private var first: TurnOutcome?
    private var second: TurnOutcome?
    private var firstWaiters: [CheckedContinuation<TurnOutcome, Never>] = []
    private var secondWaiters: [CheckedContinuation<TurnOutcome, Never>] = []

    func set(_ slot: Slot, _ value: TurnOutcome) {
        switch slot {
        case .first: first = value; firstWaiters.forEach { $0.resume(returning: value) }; firstWaiters.removeAll()
        case .second: second = value; secondWaiters.forEach { $0.resume(returning: value) }; secondWaiters.removeAll()
        }
    }

    func await(_ slot: Slot) async -> TurnOutcome {
        switch slot {
        case .first: if let first { return first }; return await withCheckedContinuation { firstWaiters.append($0) }
        case .second: if let second { return second }; return await withCheckedContinuation { secondWaiters.append($0) }
        }
    }
}

/// A brain that always throws, to exercise the `.brainError` outcome.
final class ThrowingBrain: BrainClient, @unchecked Sendable {
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        throw NSError(domain: "test", code: 401)
    }
}

/// A brain that parks inside `respond` until released, so a second concurrent trigger can be
/// observed hitting the single-in-flight guard.
final class GatedBrain: BrainClient, @unchecked Sendable {
    private let gate: AsyncGate
    private let response: BrainResponse
    init(gate: AsyncGate, response: BrainResponse) { self.gate = gate; self.response = response }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
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
