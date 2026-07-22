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

/// A brain whose per-call script can be a response OR a throw (nil), recording the messages it saw —
/// to verify what survives a failed turn and reaches the next one.
final class ScriptedThrowBrain: BrainClient, @unchecked Sendable {
    private(set) var calls: [[ChatMessage]] = []
    private var idx = 0
    let script: [BrainResponse?]
    init(script: [BrainResponse?]) { self.script = script }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        calls.append(messages)
        let r = script[min(idx, script.count - 1)]; idx += 1
        guard let r else { throw NSError(domain: "test", code: 500) }
        return r
    }
}

final class FakeScreen: ScreenCapturing, @unchecked Sendable {
    var captureCount = 0
    let payload: String
    let recognizedText: String?
    init(payload: String = "ZmFrZS1qcGVn", recognizedText: String? = nil) { // "fake-jpeg"
        self.payload = payload; self.recognizedText = recognizedText
    }
    func capture() -> ScreenSnapshot? {
        captureCount += 1
        return ScreenSnapshot(imageBase64: payload, recognizedText: recognizedText)
    }
}

final class UnavailableScreen: ScreenCapturing, @unchecked Sendable {
    func capture() -> ScreenSnapshot? { nil }
}

/// A screen whose `capture()` parks until released, so a test can cancel the turn *while the
/// (detached, un-cancellable) screenshot is in flight* — the exact window the cancellation guard
/// closes. `entered` signals capture has begun; `release` lets it return.
final class GatedScreen: ScreenCapturing, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private(set) var captureCount = 0
    let payload: String
    init(payload: String = "ZmFrZS1qcGVn") { self.payload = payload }
    func capture() -> ScreenSnapshot? {
        captureCount += 1
        entered.signal()
        release.wait()
        return ScreenSnapshot(imageBase64: payload)
    }
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

// `.serialized`: the activity-log end-to-end tests drive the shared `ActivityLog` singleton.
// Serializing the suite keeps their enable()/disable() calls from racing each other — they are the
// only code that enables the shared log, so no other suite can collide.
@Suite(.serialized) struct CoachDriverPipelineTests {
    private func makeDriver(brain: BrainClient, summarizer: BrainClient? = nil,
                            screen: ScreenCapturing = FakeScreen(),
                            overlay: OverlayRendering = FakeOverlay(),
                            clock: Clock, config: Config = .default,
                            onBrainFailure: (@Sendable (String) -> Void)? = nil)
        -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: config, transcript: transcript,
            brain: brain, summarizer: summarizer, screen: screen, overlay: overlay, clock: clock,
            onBrainFailure: onBrainFailure
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
        // The driver must hand the overlay length-scaled per-line durations, not a constant — one
        // entry per line, each = OverlayTiming.displaySeconds for that line under the active config.
        let expectedSeconds = OverlayTiming.displaySeconds(
            for: "What's the complexity of that nested loop?", config: .default)
        #expect(overlay.renderedSeconds == [[expectedSeconds]])
        #expect(brain.calls.count == 2)
        // Second brain call must replay the model's own capture call, the tool-result answering it,
        // and the screenshot image — the client-managed tool loop (no server-side conversation).
        #expect(brain.calls[1].contains { $0.role == .assistant && $0.toolCalls?.first?.name == "capture_screen" })
        #expect(brain.calls[1].contains { $0.role == .tool && $0.toolCallId == "c1" })
        #expect(brain.calls[1].contains { $0.imageBase64JPEG != nil })
        // No OCR text on this snapshot → the tool result stays the plain marker.
        #expect(brain.calls[1].first { $0.role == .tool }?.text == "screenshot captured")
    }

    /// D2 (OCR sidecar): when the capture carries recognized text, it rides in the capture_screen
    /// tool-result text — flagged as fallible OCR — right next to the image, so the model reads
    /// the exact code instead of deciphering pixels.
    @Test func recognizedTextRidesInTheCaptureToolResult() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c1")],
                  rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.speak(callId: "s1", lines: ["Check groupEnd for null before .next"])],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                             argumentsJSON: #"{"lines":["Check groupEnd for null before .next"]}"#)]),
        ])
        let screen = FakeScreen(recognizedText: "class Solution {\n    while(true){ cnt--; }")
        let (driver, transcript) = makeDriver(brain: brain, screen: screen,
                                              overlay: FakeOverlay(), clock: ManualClock(now: 100))
        transcript.append(.init(speaker: .me, text: "why is this throwing NPE", at: 100))

        await driver.handleTrigger(.turnEnd)

        let toolResult = brain.calls[1].first { $0.role == .tool && $0.toolCallId == "c1" }?.text ?? ""
        #expect(toolResult.contains("screenshot captured"))
        #expect(toolResult.contains("while(true){ cnt--; }"))     // the OCR text, verbatim
        #expect(toolResult.contains("may contain errors"))        // …flagged as fallible
        #expect(brain.calls[1].contains { $0.imageBase64JPEG != nil })   // image still ground truth
    }

    /// End-to-end: a real capture→speak turn through the production `CoachDriver` with the activity
    /// log enabled (as it is for every session). Proves the screenshot the model looked at lands in
    /// the activity log as a genuine, owner-only JPEG rendered as a clickable thumbnail linked to
    /// the full image — the behaviour verified by hand, now automated against regressions.
    ///
    /// This drives the shared `ActivityLog` singleton through the real typed activity-event path.
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
        let (driver, transcript) = makeDriver(brain: brain, screen: screen, clock: clock)
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

    /// A hotkey trigger leaves no "🗣 heard:" transcript line (the user pressed a key, didn't speak),
    /// so the manual hint must record its OWN activity line — including the synthetic message we
    /// pre-fill as the user's request — so the viewer shows what the shortcut sent to the brain.
    /// Drives the shared `ActivityLog` like the screenshot e2e above; the suite is `.serialized` so
    /// the shared-log tests don't race.
    @Test func manualHintTriggerAndPrefilledMessageLandInActivityLog() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-hintlog-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { ActivityLog.shared.disable(); try? FileManager.default.removeItem(at: dir) }
        ActivityLog.shared.enable(directory: dir)

        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["use a hash map"])])])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "stuck on two-sum", at: 100))

        await driver.handleTrigger(.manualHint)

        _ = ActivityLog.shared.attach { _ in }   // sync barrier: all async record()s have landed
        let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        // The trigger marker carries the pre-filled synthetic request ("…pressed the hint shortcut…").
        #expect(jsonl.contains("hint shortcut"))
    }

    /// The activity viewer is the human coaching record, not a second debug console. Internal turn
    /// state still belongs in `jarvis-debug.log`, while the tip produced by that turn remains visible.
    @Test func activityLogExcludesCoachingDiagnostics() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-activity-boundary-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { ActivityLog.shared.disable(); try? FileManager.default.removeItem(at: dir) }
        JarvisLog.enableFileLogging(directory: dir)
        ActivityLog.shared.enable(directory: dir)

        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "s", lines: ["activity-boundary-tip-417"])])
        ])
        let (driver, _) = makeDriver(brain: brain, clock: ManualClock(now: 417))

        #expect(await driver.handleTrigger(.silence(secondsQuiet: 417)) == .spoke)

        _ = ActivityLog.shared.attach { _ in }   // sync barrier: all async records have landed
        let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        #expect(jsonl.contains("activity-boundary-tip-417"))
        #expect(!jsonl.contains("quiet for 417s"))
        #expect(!jsonl.contains("thinking"))

        let debug = try String(contentsOf: dir.appendingPathComponent("jarvis-debug.log"), encoding: .utf8)
        #expect(debug.contains("quiet for 417s"))
        #expect(debug.contains("thinking"))
        #expect(debug.contains("activity-boundary-tip-417"))
    }

    /// Stop cancelling a turn *while the screenshot is being captured* must abort before emitting:
    /// no "👁" line, no follow-up reasoning, no `speak`. The detached capture doesn't inherit
    /// cancellation, so without the post-capture guard the screenshot (and a stale tip) would leak —
    /// into the NEW session once a Start has rotated the dev log mid-turn.
    @Test func cancelDuringCaptureAbortsBeforeEmitting() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c")],
                  rawToolCalls: [RawToolCall(id: "c", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.speak(callId: "s", lines: ["stale tip from the stopped run"])]),
        ])
        let screen = GatedScreen()
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, screen: screen, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "here is my code", at: 0))

        let task = Task { await driver.handleTrigger(.turnEnd) }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { screen.entered.wait(); cont.resume() }   // capture in flight
        }
        task.cancel()                                         // Stop fires mid-capture
        screen.release.signal()                               // let the screenshot finish

        #expect(await task.value == .cancelled)
        #expect(screen.captureCount == 1)        // captured once...
        #expect(overlay.rendered.isEmpty)        // ...but never rendered a tip after Stop
        #expect(brain.calls.count == 1)          // and never looped back to the brain with the image
    }

    /// A `speak` with an empty `lines` array (the decode fallback, or a model returning []) is passed
    /// straight through: the real overlay no-ops on it, but the turn still reports `.spoke`. Pin this
    /// so the empty-speak contract stays intentional, not incidental.
    @Test func emptySpeakLinesStillReportsSpoke() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: [])])])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(overlay.rendered == [[]])
    }

    /// The model's explicit stay-quiet decision is the `stay_silent` TOOL (tool_choice is `required`,
    /// so free-text silence can't leak into stored context): it renders nothing, reports
    /// `.silentByModel`, and leaves NO trace in the session memory — the next request carries the
    /// prior speech but neither the call nor any tool message for it.
    @Test func staySilentToolRendersNothingAndLeavesNoTrace() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "quiet1")],
                                                 rawToolCalls: [RawToolCall(id: "quiet1", name: "stay_silent", argumentsJSON: "{}")])])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "thinking about the columns", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        #expect(overlay.rendered.isEmpty)

        transcript.append(.init(speaker: .me, text: "maybe a map of columns", at: 5))
        await driver.handleTrigger(.turnEnd)
        let second = brain.calls[1]
        #expect(second.contains { ($0.text ?? "").contains("thinking about the columns") })  // memory kept
        #expect(!second.contains { $0.role == .assistant && $0.toolCalls != nil })           // no call replayed
        #expect(!second.contains { $0.role == .tool })                                       // no dangling result
    }

    /// `stay_silent` is a real brain action. It stays out of model memory, but it belongs in the
    /// human-facing Activity record so a healthy no-op cannot look like a stalled brain.
    @Test func staySilentActionLandsInActivityLog() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-silent-action-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { ActivityLog.shared.disable(); try? FileManager.default.removeItem(at: dir) }
        ActivityLog.shared.enable(directory: dir)

        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")],
                  rawToolCalls: [RawToolCall(id: "quiet", name: "stay_silent", argumentsJSON: "{}")])
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "thinking about the columns", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)

        let snapshot = ActivityLog.shared.attach { _ in }
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows[0].contains("stayed silent"))
    }

    /// A failed `capture_screen` still records the action before the model makes its terminal choice.
    @Test func failedScreenActionAndStaySilentBothLandInActivityLog() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-failed-screen-action-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { ActivityLog.shared.disable(); try? FileManager.default.removeItem(at: dir) }
        ActivityLog.shared.enable(directory: dir)

        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "capture")],
                  rawToolCalls: [RawToolCall(id: "capture", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.staySilent(callId: "quiet")],
                  rawToolCalls: [RawToolCall(id: "quiet", name: "stay_silent", argumentsJSON: "{}")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, screen: UnavailableScreen(),
                                              clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "look at this", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)

        let snapshot = ActivityLog.shared.attach { _ in }
        #expect(snapshot.rows.count == 2)
        #expect(snapshot.rows[0].contains("couldn't view your screen"))
        #expect(snapshot.rows[1].contains("stayed silent"))
    }

    /// A silence check the model shrugs at (stay_silent, nothing new said) leaves NO trace in the
    /// session memory: committing its bare trigger note would pile up answerless user messages,
    /// re-billed on every later request and confusing to read back in the request log.
    @Test func silentSilenceCheckLeavesNoTriggerNoteInHistory() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "q1")],
                                                 rawToolCalls: [RawToolCall(id: "q1", name: "stay_silent", argumentsJSON: "{}")])])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 120)) == .silentByModel)

        transcript.append(.init(speaker: .me, text: "ok here is an idea", at: 5))
        await driver.handleTrigger(.turnEnd)
        // Scoped to user messages: the system prompt legitimately shows a "(no speech for …)" example.
        #expect(!brain.calls[1].contains { $0.role == .user && ($0.text ?? "").contains("no speech for") })
    }

    /// But a silence check where the model DID look at the screen keeps the whole turn in memory —
    /// the capture (and the note that prompted it) is context a later turn can build on.
    @Test func silenceCheckWithCaptureIsKeptInHistory() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedThrowBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c1")],
                  rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.staySilent(callId: "q1")],
                  rawToolCalls: [RawToolCall(id: "q1", name: "stay_silent", argumentsJSON: "{}")]),
            .init(toolCalls: []),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 120)) == .silentByModel)

        transcript.append(.init(speaker: .me, text: "ok here is an idea", at: 5))
        await driver.handleTrigger(.turnEnd)
        let last = brain.calls.last!
        #expect(last.contains { $0.role == .user && ($0.text ?? "").contains("no speech for") })   // the note survives
        #expect(last.contains { $0.role == .tool && $0.toolCallId == "c1" })                        // with its capture
    }

    /// Defensive: a model that answers with NO tool call despite `required` still reads as deliberate
    /// silence — render nothing rather than fail the turn.
    @Test func noToolCallsStillRendersNothing() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        #expect(overlay.rendered.isEmpty)
    }

    // MARK: - The substance gate: filler never buys a brain request

    /// A turn-end whose whole delta is back-channel filler — from EITHER speaker — is skipped without
    /// a request: filler can't produce a tip, and the request would only re-bill the working set.
    @Test func fillerOnlyTurnEndSkipsTheBrain() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .them, text: "Hmm.", at: 1))
        transcript.append(.init(speaker: .me, text: "嗯嗯", at: 2))
        #expect(await driver.handleTrigger(.turnEnd) == .skippedFillerOnly)
        #expect(brain.calls.isEmpty)
    }

    /// The gate is speaker-NEUTRAL: an interviewer question is substance and reaches the brain — the
    /// prompt lets the model offer the user a proactive tip for answering it.
    @Test func interviewerQuestionReachesTheBrain() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["Walk through your loop out loud."])])])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .them, text: "那你是怎么做的?", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(brain.calls.count == 1)
    }

    /// An empty-delta turn-end (fragments already sent last turn) is skipped the same way.
    @Test func emptyDeltaTurnEndSkipsTheBrain() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let (driver, _) = makeDriver(brain: brain, clock: clock)
        #expect(await driver.handleTrigger(.turnEnd) == .skippedFillerOnly)
        #expect(brain.calls.isEmpty)
    }

    /// Skipped filler is NOT lost: the sent-index doesn't advance on a skip, so it rides along with
    /// the next substantive turn in one request.
    @Test func skippedFillerRidesAlongOnTheNextTurn() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .them, text: "嗯", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .skippedFillerOnly)
        transcript.append(.init(speaker: .me, text: "I'd check both neighbors at that height", at: 5))
        await driver.handleTrigger(.turnEnd)
        let userText = brain.calls[0].compactMap { $0.text }.joined(separator: " ")
        #expect(userText.contains("嗯"))                                     // filler context arrived...
        #expect(userText.contains("I'd check both neighbors at that height")) // ...with the real line
    }

    /// Silence wake-ups are NOT gated: with nothing new said, the model may still want to look at the
    /// screen and nudge — the gate applies to turn-ends only.
    @Test func silenceTriggerStillReachesTheBrainWithoutNewSpeech() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let (driver, _) = makeDriver(brain: brain, clock: clock)
        await driver.handleTrigger(.silence(secondsQuiet: 120))
        #expect(brain.calls.count == 1)
    }

    // MARK: - Client-managed session memory (CoachHistory)

    /// The next request carries the whole prior turn: the user's words, the model's `speak` call, and
    /// the tool-result closing it — continuity without any server-side conversation.
    @Test func historyCarriesPriorTurnToNextRequest() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "spk1", lines: ["hi"])],
                  rawToolCalls: [RawToolCall(id: "spk1", name: "speak", argumentsJSON: #"{"lines":["hi"]}"#)]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "the whole problem statement", at: 0))
        await driver.handleTrigger(.turnEnd)
        transcript.append(.init(speaker: .me, text: "new thought", at: 5))
        await driver.handleTrigger(.turnEnd)
        let second = brain.calls[1]
        #expect(second.contains { ($0.text ?? "").contains("the whole problem statement") })
        #expect(second.contains { $0.role == .assistant && $0.toolCalls?.first?.name == "speak" })
        #expect(second.contains { $0.role == .tool && $0.toolCallId == "spk1" })
    }

    /// The delta is sent once: a line already carried by an earlier turn appears in the next request
    /// only via history (exactly once), never re-sent as new speech.
    @Test func indexDeltaSendsEachLineExactlyOnce() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])   // stays silent → one call per turn
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "two sum brute force", at: 1))
        await driver.handleTrigger(.turnEnd)
        transcript.append(.init(speaker: .me, text: "maybe a hash map", at: 5))
        await driver.handleTrigger(.turnEnd)
        let allText = brain.calls[1].compactMap(\.text).joined(separator: "\n")
        #expect(allText.contains("maybe a hash map"))
        let occurrences = allText.components(separatedBy: "two sum brute force").count - 1
        #expect(occurrences == 1)   // in history once; NOT re-sent as a new delta
    }

    /// Speech is NOT marked sent on a failed turn — it is re-sent next turn (advance-on-success).
    @Test func unsentSpeechResentAfterBrainError() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedThrowBrain(script: [nil, .init(toolCalls: [])])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "important words", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)   // first call throws, not sent
        await driver.handleTrigger(.turnEnd)
        #expect(brain.calls.last!.contains { ($0.text ?? "").contains("important words") })   // re-sent
    }

    /// Reasoning passthrough: a capture_screen response's WHOLE output (reasoning + the function_call
    /// with its item id) rides verbatim into the tool loop's next request, ahead of the tool result —
    /// the canonical `input.push(...response.output)` loop. Commit converts it: the next turn's
    /// request carries the id-less synthetic call instead, and no reasoning.
    @Test func reasoningItemsRideTheToolLoopButNotMemory() async {
        let outputItems = [
            #"{"type":"reasoning","id":"rs_1"}"#,
            #"{"type":"function_call","id":"fc_1","call_id":"c1","name":"capture_screen","arguments":"{}"}"#,
        ]
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c1")],
                  rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")],
                  outputItemsJSON: outputItems),
            .init(toolCalls: [.speak(callId: "s1", lines: ["tip"])],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak", argumentsJSON: "{}")]),
            .init(toolCalls: []),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "look at this", at: 0))
        await driver.handleTrigger(.turnEnd)
        transcript.append(.init(speaker: .me, text: "another thought", at: 5))
        await driver.handleTrigger(.turnEnd)

        // Within the turn: one verbatim passthrough message, whole and in order, before the result.
        let second = brain.calls[1]
        let rawIndex = second.firstIndex { $0.rawItemsJSON != nil }
        let resultIndex = second.firstIndex { $0.role == .tool && $0.toolCallId == "c1" }
        #expect(rawIndex != nil && resultIndex != nil)
        if let r = rawIndex, let t = resultIndex { #expect(r < t) }
        #expect(second.first { $0.rawItemsJSON != nil }?.rawItemsJSON == outputItems)
        #expect(!second.contains { $0.toolCalls?.contains { $0.name == "capture_screen" } ?? false })   // no duplicate synthetic call

        // After commit: reasoning gone, the call converted to the id-less synthetic history shape.
        let third = brain.calls[2]
        #expect(!third.contains { $0.rawItemsJSON != nil })
        #expect(third.contains { $0.toolCalls == [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")] })
    }

    /// Observation masking: a screenshot only lives within the turn that took it — once the turn
    /// commits, later requests carry a text stub instead of pixels.
    @Test func screenshotsStubbedAfterTheirTurnCommits() async {
        let clock = ManualClock(now: 0)
        // Every turn: capture then speak. ScriptedBrain repeats the last entry, so we script one
        // capture+speak pair and run it twice, then inspect the request of a third turn.
        let brain = ScriptedThrowBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c1")],
                  rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.speak(callId: "s1", lines: ["tip one"])],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak", argumentsJSON: "{}")]),
            .init(toolCalls: [.captureScreen(callId: "c2")],
                  rawToolCalls: [RawToolCall(id: "c2", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.speak(callId: "s2", lines: ["tip two"])],
                  rawToolCalls: [RawToolCall(id: "s2", name: "speak", argumentsJSON: "{}")]),
            .init(toolCalls: []),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "first look please", at: 0))
        await driver.handleTrigger(.turnEnd)
        transcript.append(.init(speaker: .me, text: "second look please", at: 5))
        await driver.handleTrigger(.turnEnd)
        transcript.append(.init(speaker: .me, text: "and one more thought", at: 9))
        await driver.handleTrigger(.turnEnd)

        let last = brain.calls.last!
        #expect(!last.contains { $0.imageBase64JPEG != nil })                            // no pixels survive
        #expect(last.filter { ($0.text ?? "").contains("no longer available") }.count == 2)   // a stub each
    }

    // MARK: - Compaction

    /// Past the threshold, the oldest span of memory is replaced by the summarizer's briefing; a
    /// later request opens with the condensed block instead of the raw early turns.
    @Test func historyCompactsIntoSummaryPastThreshold() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let summarizer = ScriptedBrain(script: [.init(toolCalls: [], outputText: "PROBLEM: tic-tac-toe columns.")])
        let (driver, transcript) = makeDriver(brain: brain, summarizer: summarizer, clock: clock,
                                              config: Config(historyCompactionTokenThreshold: 30))
        transcript.append(.init(speaker: .me, text: String(repeating: "the problem statement goes on ", count: 8), at: 0))
        await driver.handleTrigger(.turnEnd)   // one long message — nothing to split yet
        transcript.append(.init(speaker: .me, text: "and some more detail about the grid", at: 1))
        await driver.handleTrigger(.turnEnd)   // a second message pushes past the threshold → compaction

        #expect(summarizer.calls.count == 1)   // the summarizer (not the coach brain) wrote it
        transcript.append(.init(speaker: .me, text: "next idea entirely", at: 5))
        await driver.handleTrigger(.turnEnd)
        let third = brain.calls[2].compactMap(\.text).joined(separator: "\n")
        #expect(third.contains("condensed"))
        #expect(third.contains("PROBLEM: tic-tac-toe columns."))
        #expect(!third.contains("the problem statement goes on"))   // raw early turn replaced
    }

    /// Compaction fails soft: if the summarizer errors, the full history simply rides along.
    @Test func compactionFailureKeepsFullHistory() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let summarizer = ScriptedThrowBrain(script: [nil])
        let (driver, transcript) = makeDriver(brain: brain, summarizer: summarizer, clock: clock,
                                              config: Config(historyCompactionTokenThreshold: 5))
        transcript.append(.init(speaker: .me, text: "a reasonably long problem statement to remember", at: 0))
        await driver.handleTrigger(.turnEnd)
        transcript.append(.init(speaker: .me, text: "next thought", at: 5))
        await driver.handleTrigger(.turnEnd)
        let second = brain.calls[1].compactMap(\.text).joined(separator: "\n")
        #expect(second.contains("a reasonably long problem statement to remember"))   // nothing lost
    }

    // MARK: - Observability: structured turn outcomes

    @Test func spokeOutcome() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", lines: ["hi"])])])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
    }

    @Test func silentByModelOutcomeWhenStaySilentCalled() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "q")])])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
    }

    /// No cooldown: two back-to-back substantive turns both reach the brain and both speak.
    @Test func consecutiveTurnsBothReachBrain() async {
        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", lines: ["first"])])])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "first idea about the grid", at: 100))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        transcript.append(.init(speaker: .me, text: "second idea about the rows", at: 101))
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
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
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
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "look at this code", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .exhausted)
        #expect(overlay.rendered.isEmpty)
    }

    @Test func brainErrorOutcome() async {
        let clock = ManualClock(now: 0)
        let brain = ThrowingBrain()
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
    }

    @Test func brainErrorReportsTheFailureReason() async {
        let recorder = BrainFailureRecorder()
        let (driver, transcript) = makeDriver(
            brain: ThrowingBrain(), clock: ManualClock(now: 0),
            onBrainFailure: { recorder.record($0) }
        )
        transcript.append(.init(speaker: .me, text: "please help with this problem", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(recorder.messages == ["test brain failed"])
    }

    @Test func terminalBrainErrorDropsCoalescedAndLaterTriggers() async {
        let clock = ManualClock(now: 0)
        let gate = AsyncGate()
        let brain = GatedThrowingBrain(gate: gate)
        let recorder = BrainFailureRecorder()
        let (driver, transcript) = makeDriver(
            brain: brain, clock: clock,
            onBrainFailure: { recorder.record($0) }
        )
        transcript.append(.init(speaker: .me, text: "first substantial question", at: 0))
        async let first = driver.handleTrigger(.turnEnd)
        await gate.waitUntilEntered()
        transcript.append(.init(speaker: .me, text: "second substantial question", at: 1))

        #expect(await driver.handleTrigger(.turnEnd) == .busy)
        await gate.release()
        #expect(await first == .brainError)
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(brain.callCount == 1)
        #expect(recorder.messages == ["gated brain failed"])
    }

    /// Audio-driven turns REQUIRE a tool call (never free text): the model picks which tool from the
    /// prompt — reply, look at the screen, or stay_silent — but must answer with one of them.
    @Test func everyAudioTurnRequiresAToolCall() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", lines: ["hi"])])])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        await driver.handleTrigger(.turnEnd)
        #expect(brain.toolChoices.last == .required)
    }

    /// While one turn is in flight, a second concurrent trigger must be reported as `.busy` AND
    /// coalesced: the running turn picks it up and runs it too, so nothing is dropped.
    @Test func concurrentTriggerIsBusyThenCoalesced() async {
        let clock = ManualClock(now: 0)
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, response: .init(toolCalls: [.speak(callId: "s1", lines: ["hi"])]))
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "first idea about the grid", at: 0))
        async let first = driver.handleTrigger(.turnEnd)   // parks in the brain call, holds the slot
        await gate.waitUntilEntered()
        transcript.append(.init(speaker: .me, text: "second idea about the rows", at: 1))
        let second = await driver.handleTrigger(.turnEnd)  // busy → queued as pending
        #expect(second == .busy)
        await gate.release()
        _ = await first
        #expect(brain.callCount >= 2)                      // the original AND the coalesced turn ran
    }
}

/// A brain that always throws, to exercise the `.brainError` outcome.
final class ThrowingBrain: BrainClient, @unchecked Sendable {
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        throw NSError(domain: "test", code: 401,
                      userInfo: [NSLocalizedDescriptionKey: "test brain failed"])
    }
}

/// Lock-guarded because `CoachDriver`'s failure callback is `@Sendable`.
final class BrainFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ message: String) { lock.lock(); recorded.append(message); lock.unlock() }
}

/// A brain that parks inside `respond` until released, so a second concurrent trigger can be
/// observed hitting the single-in-flight guard.
final class GatedBrain: BrainClient, @unchecked Sendable {
    private let gate: AsyncGate
    private let response: BrainResponse
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    private func record() { lock.lock(); _callCount += 1; lock.unlock() }
    init(gate: AsyncGate, response: BrainResponse) { self.gate = gate; self.response = response }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        record()
        await gate.enter()
        return response
    }
}

/// A throwing brain with the same one-shot gate, so a second trigger can pend before the terminal
/// failure is released.
final class GatedThrowingBrain: BrainClient, @unchecked Sendable {
    private let gate: AsyncGate
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    init(gate: AsyncGate) { self.gate = gate }
    private func recordCall() { lock.lock(); _callCount += 1; lock.unlock() }
    func respond(messages: [ChatMessage], tools: [ToolDef],
                 toolChoice: ToolChoice) async throws -> BrainResponse {
        recordCall()
        await gate.enter()
        throw NSError(domain: "test", code: 401,
                      userInfo: [NSLocalizedDescriptionKey: "gated brain failed"])
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
