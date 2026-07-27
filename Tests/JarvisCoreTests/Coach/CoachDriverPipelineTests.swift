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
    private func makeDriver(brain: BrainClient, brainProvider: BrainProvider? = nil,
                            summarizer: BrainClient? = nil,
                            screen: ScreenCapturing = FakeScreen(),
                            overlay: OverlayRendering = FakeOverlay(),
                            clock: Clock, config: Config = .default,
                            onBrainFailure: (@MainActor @Sendable (BrainFailure) -> Void)? = nil)
        -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let provider = brainProvider ?? .openAI
        let target = BrainTarget(
            provider: provider,
            modelID: BrainModelCatalog.defaultModel(for: provider).id)
        let route = ConfiguredBrainRoute(
            targets: [
                ConfiguredBrainTarget(target: target, brain: brain, summarizer: summarizer),
            ],
            onExhausted: { _, failure in onBrainFailure?(failure) })
        let driver = CoachDriver(
            config: config, transcript: transcript,
            route: route, screen: screen, overlay: overlay, clock: clock,
            automaticAttemptDelay: { _ in }
        )
        return (driver, transcript)
    }

    private func makeRouteDriver(
        _ targets: [(BrainTarget, BrainClient)],
        screen: ScreenCapturing = FakeScreen(),
        overlay: OverlayRendering = FakeOverlay(),
        onAdvanced: (@Sendable (BrainTarget, BrainTarget) -> Void)? = nil,
        onSkipped: (@Sendable (BrainTarget) -> Void)? = nil,
        onExhausted: (@MainActor @Sendable (BrainTarget, BrainFailure) -> Void)? = nil
    ) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let route = ConfiguredBrainRoute(
            targets: targets.map {
                ConfiguredBrainTarget(target: $0.0, brain: $0.1)
            },
            onAdvanced: onAdvanced,
            onSkipped: onSkipped,
            onExhausted: onExhausted)
        return (
            CoachDriver(
                config: .default,
                transcript: transcript,
                route: route,
                screen: screen,
                overlay: overlay,
                clock: ManualClock(),
                automaticAttemptDelay: { _ in }),
            transcript)
    }

    private func installSingleTarget(
        _ brain: BrainClient,
        provider: BrainProvider = .openAI,
        on driver: CoachDriver
    ) {
        let target = BrainTarget(
            provider: provider,
            modelID: BrainModelCatalog.defaultModel(for: provider).id)
        driver.updateBrainRoute(ConfiguredBrainRoute(targets: [
            ConfiguredBrainTarget(target: target, brain: brain),
        ]))
    }

    private func waitUntilRouteReportsExhaustion(_ driver: CoachDriver) async -> Bool {
        for _ in 0..<1_000 {
            if await driver.handleTrigger(.turnEnd) == .brainError {
                return true
            }
            await Task.yield()
        }
        return false
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

    @Test func nonExhaustingAttemptFailuresLandInActivityBeforeRecovery() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "jarvis-attempt-failure-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { ActivityLog.shared.disable(); try? FileManager.default.removeItem(at: dir) }
        ActivityLog.shared.enable(directory: dir)

        let brain = ScriptedThrowBrain(script: [
            nil,
            nil,
            .init(toolCalls: [.speak(callId: "recovered", lines: ["recovered coaching"])]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "keep listening after failures", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let snapshot = ActivityLog.shared.attach { _ in }
        #expect(snapshot.rows.count == 3)
        #expect(snapshot.rows[0].contains("couldn't respond this turn"))
        #expect(snapshot.rows[0].contains("listening continues"))
        #expect(snapshot.rows[1].contains("couldn't respond this turn"))
        #expect(snapshot.rows[1].contains("listening continues"))
        #expect(snapshot.rows[2].contains("recovered coaching"))
        #expect(!snapshot.rows.joined().contains("test"))
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

    /// Empty speech is an invalid terminal action: it never renders or commits a spoken turn.
    @Test func emptySpeakLinesAreRejected() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: [])])])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(overlay.rendered.isEmpty)
        #expect(brain.calls.count == BrainRouteSession.failuresPerTarget)
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

    /// A failed `capture_screen` records the action and fixed recovery guidance before the model
    /// makes its terminal choice.
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
        #expect(snapshot.rows[0].contains("screen capture failed"))
        #expect(snapshot.rows[0].contains("Screen Recording permission"))
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
            .init(toolCalls: [.staySilent(callId: "quiet-next")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 120)) == .silentByModel)

        transcript.append(.init(speaker: .me, text: "ok here is an idea", at: 5))
        await driver.handleTrigger(.turnEnd)
        let last = brain.calls.last!
        #expect(last.contains { $0.role == .user && ($0.text ?? "").contains("no speech for") })   // the note survives
        #expect(last.contains { $0.role == .tool && $0.toolCallId == "c1" })                        // with its capture
    }

    /// A complete response that ignores `tool_choice: required` is a failed attempt, not a
    /// deliberate silence decision.
    @Test func noToolCallsExhaustTheOnlyTargetWithoutRendering() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(brain.calls.count == 3)
        #expect(overlay.rendered.isEmpty)
    }

    // MARK: - The substance gate: filler never buys a brain request

    /// A turn-end whose whole delta is back-channel filler — from EITHER speaker — is skipped without
    /// a request: filler can't produce a tip, and the request would only re-bill the working set.
    @Test func fillerOnlyTurnEndSkipsTheBrain() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
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
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, _) = makeDriver(brain: brain, clock: clock)
        #expect(await driver.handleTrigger(.turnEnd) == .skippedFillerOnly)
        #expect(brain.calls.isEmpty)
    }

    /// Skipped filler is NOT lost: the sent-index doesn't advance on a skip, so it rides along with
    /// the next substantive turn in one request.
    @Test func skippedFillerRidesAlongOnTheNextTurn() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
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
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, _) = makeDriver(brain: brain, clock: clock)
        await driver.handleTrigger(.silence(secondsQuiet: 120))
        #expect(brain.calls.count == 1)
    }

    @Test func fillerWakeCannotCancelFailedSilenceAttempt() async {
        let gate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(
            brain: brain,
            overlay: overlay,
            clock: ManualClock())

        async let outcome = driver.handleTrigger(.silence(secondsQuiet: 120))
        await gate.waitUntilEntered()
        transcript.append(.init(speaker: .them, text: "嗯", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .busy)
        await gate.release()

        #expect(await outcome == .spoke)
        #expect(brain.calls.count == 2)
        #expect(overlay.rendered == [["recovered pending turn"]])
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

    /// Changing provider/model is a model-layer swap, not a new coaching session: the replacement
    /// receives the existing client-managed history plus only the transcript delta it has not seen.
    @Test func brainUpdateAppliesToNextTurnWithoutLosingHistory() async {
        let clock = ManualClock(now: 0)
        let firstBrain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "old", lines: ["first tip"])],
                  rawToolCalls: [RawToolCall(id: "old", name: "speak",
                                             argumentsJSON: #"{"lines":["first tip"]}"#)]),
        ])
        let nextBrain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "new", lines: ["second tip"])],
                  rawToolCalls: [RawToolCall(id: "new", name: "speak",
                                             argumentsJSON: #"{"lines":["second tip"]}"#)]),
        ])
        let (driver, transcript) = makeDriver(brain: firstBrain, clock: clock)
        transcript.append(.init(speaker: .me, text: "the original problem", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        installSingleTarget(nextBrain, on: driver)
        transcript.append(.init(speaker: .me, text: "my next idea", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        #expect(firstBrain.calls.count == 1)
        #expect(nextBrain.calls.count == 1)
        let replacementContext = nextBrain.calls[0]
        #expect(replacementContext.contains { ($0.text ?? "").contains("the original problem") })
        #expect(replacementContext.contains { ($0.text ?? "").contains("my next idea") })
        #expect(replacementContext.contains { $0.role == .assistant && $0.toolCalls?.first?.id == "old" })
        #expect(replacementContext.contains { $0.role == .tool && $0.toolCallId == "old" })
    }

    /// One capture/tool loop is one provider transaction. A switch during its first request waits
    /// for the next turn instead of sending the captured result to a different provider/model.
    @Test func brainUpdateDoesNotSplitAnInFlightToolLoop() async {
        let clock = ManualClock(now: 0)
        let gate = AsyncGate()
        let oldBrain = GatedBrain(gate: gate, script: [
            .init(toolCalls: [.captureScreen(callId: "capture")],
                  rawToolCalls: [RawToolCall(id: "capture", name: "capture_screen",
                                             argumentsJSON: "{}")]),
            .init(toolCalls: [.speak(callId: "old", lines: ["old provider finished"])],
                  rawToolCalls: [RawToolCall(id: "old", name: "speak",
                                             argumentsJSON: #"{"lines":["old provider finished"]}"#)]),
        ])
        let nextBrain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "new", lines: ["new provider turn"])],
                  rawToolCalls: [RawToolCall(id: "new", name: "speak",
                                             argumentsJSON: #"{"lines":["new provider turn"]}"#)]),
        ])
        let (driver, transcript) = makeDriver(brain: oldBrain, clock: clock)
        transcript.append(.init(speaker: .me, text: "inspect this code", at: 0))
        async let oldTurn = driver.handleTrigger(.turnEnd)
        await gate.waitUntilEntered()

        installSingleTarget(nextBrain, on: driver)
        await gate.release()
        #expect(await oldTurn == .spoke)
        #expect(oldBrain.callCount == 2)
        #expect(nextBrain.calls.isEmpty)

        transcript.append(.init(speaker: .me, text: "now continue", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(nextBrain.calls.count == 1)
    }

    /// A manual hint starts before its detached screenshot finishes. Settings changes during that
    /// capture belong to the next turn; the captured hint must finish on its original provider.
    @Test func brainUpdateDuringManualHintCaptureAppliesToNextTurn() async {
        let clock = ManualClock(now: 0)
        let screen = GatedScreen()
        let oldBrain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "old", lines: ["old provider hint"])],
                  rawToolCalls: [RawToolCall(id: "old", name: "speak",
                                             argumentsJSON: #"{"lines":["old provider hint"]}"#)]),
        ])
        let nextBrain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "new", lines: ["new provider turn"])],
                  rawToolCalls: [RawToolCall(id: "new", name: "speak",
                                             argumentsJSON: #"{"lines":["new provider turn"]}"#)]),
        ])
        let (driver, transcript) = makeDriver(
            brain: oldBrain, screen: screen, clock: clock)
        transcript.append(.init(speaker: .me, text: "help with what is on screen", at: 0))
        async let hintTurn = driver.handleTrigger(.manualHint)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { screen.entered.wait(); cont.resume() }
        }

        installSingleTarget(nextBrain, on: driver)
        screen.release.signal()
        #expect(await hintTurn == .spoke)
        #expect(oldBrain.calls.count == 1)
        #expect(nextBrain.calls.isEmpty)

        transcript.append(.init(speaker: .me, text: "continue with the new provider", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(nextBrain.calls.count == 1)
    }

    @Test func threeTemporaryFailuresAdvanceOnAFreshAttempt() async {
        let primaryTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let fallbackTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let primary = ThrowingBrain()
        let fallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "fallback", lines: ["fallback tip"])]),
        ])
        let transitions = RouteTransitionRecorder()
        let (driver, transcript) = makeRouteDriver(
            [(primaryTarget, primary), (fallbackTarget, fallback)],
            onAdvanced: { transitions.record(from: $0, to: $1) })
        transcript.append(.init(speaker: .me, text: "preserve this pending work", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(primary.callCount == 3)
        #expect(fallback.calls.count == 1)
        #expect(fallback.calls[0].contains {
            ($0.text ?? "").contains("preserve this pending work")
        })
        #expect(transitions.events == [.init(from: primaryTarget, to: fallbackTarget)])
    }

    @Test func permanentFailureAdvancesAfterOneAttempt() async {
        let primaryTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let fallbackTarget = BrainTarget(provider: .codexCLI, modelID: "gpt-5.6-sol")
        let primary = ThrowingBrain(error: BrainFailure(
            disposition: .permanent,
            detail: "invalid credentials"))
        let fallback = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeRouteDriver([
            (primaryTarget, primary),
            (fallbackTarget, fallback),
        ])
        transcript.append(.init(speaker: .me, text: "try the next provider", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        #expect(primary.callCount == 1)
        #expect(fallback.calls.count == 1)
    }

    @Test func successfulFallbackRemainsActiveForLaterConversation() async {
        let primary = ThrowingBrain()
        let fallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "fallback", lines: ["still on fallback"])]),
        ])
        let (driver, transcript) = makeRouteDriver([
            (BrainTarget(provider: .openAI, modelID: "gpt-5.5"), primary),
            (BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5"), fallback),
        ])
        transcript.append(.init(speaker: .me, text: "first question", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        transcript.append(.init(speaker: .me, text: "second question", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        #expect(primary.callCount == 3)
        #expect(fallback.calls.count == 2)
    }

    @Test func refreshingRouteClientsPreservesFallbackCursor() async {
        let primaryTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let fallbackTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let primary = ThrowingBrain(error: BrainFailure(
            disposition: .permanent,
            detail: "primary permanently failed"))
        let originalFallback = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "original-fallback")]),
        ])
        let (driver, transcript) = makeRouteDriver([
            (primaryTarget, primary),
            (fallbackTarget, originalFallback),
        ])
        transcript.append(.init(speaker: .me, text: "move to fallback", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)

        let refreshedPrimary = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "wrong-target", lines: ["went backward"])]),
        ])
        let refreshedFallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "refreshed", lines: ["new key works"])]),
        ])
        #expect(driver.refreshBrainRouteClients(ConfiguredBrainRoute(targets: [
            ConfiguredBrainTarget(target: primaryTarget, brain: refreshedPrimary),
            ConfiguredBrainTarget(target: fallbackTarget, brain: refreshedFallback),
        ])))

        transcript.append(.init(speaker: .me, text: "continue on fallback", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(refreshedPrimary.calls.isEmpty)
        #expect(refreshedFallback.calls.count == 1)
    }

    @Test func reconfiguringRouteClientsPreservesFallbackCursor() async {
        let primaryTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let fallbackTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let primary = ThrowingBrain(error: BrainFailure(
            disposition: .permanent,
            detail: "primary permanently failed"))
        let originalFallback = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "original-fallback")]),
        ])
        let (driver, transcript) = makeRouteDriver([
            (primaryTarget, primary),
            (fallbackTarget, originalFallback),
        ])
        transcript.append(.init(speaker: .me, text: "move to fallback", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)

        let reconfiguredPrimary = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "wrong-target", lines: ["went backward"])]),
        ])
        let reconfiguredFallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "effort", lines: ["new effort"])]),
        ])
        #expect(driver.reconfigureBrainRouteClients(ConfiguredBrainRoute(targets: [
            ConfiguredBrainTarget(target: primaryTarget, brain: reconfiguredPrimary),
            ConfiguredBrainTarget(target: fallbackTarget, brain: reconfiguredFallback),
        ])))

        transcript.append(.init(speaker: .me, text: "continue on fallback", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(reconfiguredPrimary.calls.isEmpty)
        #expect(reconfiguredFallback.calls.count == 1)
    }

    @Test func scopedCredentialRefreshKeepsOtherProviderClients() async {
        let primaryTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let fallbackTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let originalPrimary = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "original-primary")]),
        ])
        let originalFallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "original-fallback", lines: ["retained CLI"])]),
        ])
        let (driver, transcript) = makeRouteDriver([
            (primaryTarget, originalPrimary),
            (fallbackTarget, originalFallback),
        ])
        transcript.append(.init(speaker: .me, text: "establish primary", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)

        let refreshedPrimary = ThrowingBrain(error: BrainFailure(
            disposition: .permanent,
            detail: "new credential rejected"))
        let unwantedFallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "wrong-client", lines: ["replaced CLI"])]),
        ])
        #expect(driver.refreshBrainRouteClients(
            ConfiguredBrainRoute(targets: [
                ConfiguredBrainTarget(target: primaryTarget, brain: refreshedPrimary),
                ConfiguredBrainTarget(target: fallbackTarget, brain: unwantedFallback),
            ]),
            for: [.openAI]))

        transcript.append(.init(speaker: .me, text: "advance after refresh", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(refreshedPrimary.callCount == 1)
        #expect(originalFallback.calls.count == 1)
        #expect(unwantedFallback.calls.isEmpty)
    }

    @Test func scopedCredentialRefreshKeepsOtherProviderInFlightFailureValid() async {
        let primaryTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let fallbackTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let failureGate = AsyncGate()
        let originalPrimary = TwoFailuresThenGatedFailureBrain(gate: failureGate)
        let originalFallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "old-key", lines: ["wrong OpenAI client"])]),
        ])
        let (driver, transcript) = makeRouteDriver([
            (primaryTarget, originalPrimary),
            (fallbackTarget, originalFallback),
        ])
        transcript.append(.init(speaker: .me, text: "keep CLI failure valid", at: 0))

        async let outcome = driver.handleTrigger(.turnEnd)
        await failureGate.waitUntilEntered()

        let unwantedPrimary = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "wrong-cli", lines: ["replaced CLI"])]),
        ])
        let refreshedFallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "new-key", lines: ["refreshed OpenAI"])]),
        ])
        #expect(driver.refreshBrainRouteClients(
            ConfiguredBrainRoute(targets: [
                ConfiguredBrainTarget(target: primaryTarget, brain: unwantedPrimary),
                ConfiguredBrainTarget(target: fallbackTarget, brain: refreshedFallback),
            ]),
            for: [.openAI]))
        await failureGate.release()

        #expect(await outcome == .spoke)
        #expect(originalPrimary.callCount == 3)
        #expect(unwantedPrimary.calls.isEmpty)
        #expect(originalFallback.calls.isEmpty)
        #expect(refreshedFallback.calls.count == 1)
    }

    @Test func refreshingClientsCannotDropOrRedirectACommittedSkip() async {
        let unavailableTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let availableTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let originalAvailable = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "old-client")]),
        ])
        let originalSkip = RouteTargetRecorder()
        let refreshedSkip = RouteTargetRecorder()
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default,
            transcript: transcript,
            route: ConfiguredBrainRoute(
                targets: [
                    ConfiguredBrainTarget(
                        unavailable: unavailableTarget,
                        detail: "Claude Code is signed out"),
                    ConfiguredBrainTarget(target: availableTarget, brain: originalAvailable),
                ],
                onSkipped: { originalSkip.record($0) }),
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })
        transcript.append(.init(speaker: .me, text: "skip without losing the notice", at: 0))

        let mainActorEntered = DispatchSemaphore(value: 0)
        let releaseMainActor = DispatchSemaphore(value: 0)
        let mainActorBlocker = Task { @MainActor in
            blockMainActor(entered: mainActorEntered, release: releaseMainActor)
        }
        await waitForSemaphore(mainActorEntered)
        async let outcome = driver.handleTrigger(.turnEnd)
        await allowPendingRouteDeliveryToReachMainActor()

        let refreshedAvailable = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "new-client")]),
        ])
        #expect(driver.refreshBrainRouteClients(ConfiguredBrainRoute(
            targets: [
                ConfiguredBrainTarget(
                    unavailable: unavailableTarget,
                    detail: "Claude Code is still signed out"),
                ConfiguredBrainTarget(target: availableTarget, brain: refreshedAvailable),
            ],
            onSkipped: { refreshedSkip.record($0) })))

        releaseMainActor.signal()
        await mainActorBlocker.value
        #expect(await outcome == .silentByModel)
        #expect(originalSkip.targets == [unavailableTarget])
        #expect(refreshedSkip.targets.isEmpty)
        #expect(originalAvailable.calls.isEmpty)
        #expect(refreshedAvailable.calls.count == 1)
    }

    @Test func refreshingClientsCannotDropOrRedirectACommittedAdvance() async {
        let primaryTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let fallbackTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let responseGate = AsyncGate()
        let originalPrimary = GatedThrowingBrain(
            gate: responseGate,
            error: BrainFailure(
                disposition: .permanent,
                detail: "primary permanently failed"))
        let originalFallback = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "old-fallback")]),
        ])
        let originalAdvance = RouteTransitionRecorder()
        let refreshedAdvance = RouteTransitionRecorder()
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default,
            transcript: transcript,
            route: ConfiguredBrainRoute(
                targets: [
                    ConfiguredBrainTarget(target: primaryTarget, brain: originalPrimary),
                    ConfiguredBrainTarget(target: fallbackTarget, brain: originalFallback),
                ],
                onAdvanced: {
                    originalAdvance.record(from: $0, to: $1)
                }),
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })
        transcript.append(.init(speaker: .me, text: "advance without losing the notice", at: 0))

        async let outcome = driver.handleTrigger(.turnEnd)
        await responseGate.waitUntilEntered()
        let mainActorEntered = DispatchSemaphore(value: 0)
        let releaseMainActor = DispatchSemaphore(value: 0)
        let mainActorBlocker = Task { @MainActor in
            blockMainActor(entered: mainActorEntered, release: releaseMainActor)
        }
        await waitForSemaphore(mainActorEntered)
        await responseGate.release()
        await allowPendingRouteDeliveryToReachMainActor()

        let refreshedPrimary = ThrowingBrain(error: BrainFailure(
            disposition: .permanent,
            detail: "refreshed primary should not run"))
        let refreshedFallback = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "new-fallback")]),
        ])
        #expect(driver.refreshBrainRouteClients(ConfiguredBrainRoute(
            targets: [
                ConfiguredBrainTarget(target: primaryTarget, brain: refreshedPrimary),
                ConfiguredBrainTarget(target: fallbackTarget, brain: refreshedFallback),
            ],
            onAdvanced: {
                refreshedAdvance.record(from: $0, to: $1)
            })))

        releaseMainActor.signal()
        await mainActorBlocker.value
        #expect(await outcome == .silentByModel)
        #expect(originalAdvance.events == [
            .init(from: primaryTarget, to: fallbackTarget),
        ])
        #expect(refreshedAdvance.events.isEmpty)
        #expect(originalFallback.calls.isEmpty)
        #expect(refreshedPrimary.callCount == 0)
        #expect(refreshedFallback.calls.count == 1)
    }

    @Test func inFlightSuccessAcrossClientRefreshResetsTheFailureSequence() async {
        let primaryTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let fallbackTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let successGate = AsyncGate()
        let originalPrimary = TwoFailuresThenGatedSuccessBrain(gate: successGate)
        let fallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "fallback", lines: ["should not advance"])]),
        ])
        let (driver, transcript) = makeRouteDriver([
            (primaryTarget, originalPrimary),
            (fallbackTarget, fallback),
        ])
        transcript.append(.init(speaker: .me, text: "complete across the key refresh", at: 0))

        async let firstOutcome = driver.handleTrigger(.turnEnd)
        await successGate.waitUntilEntered()

        let refreshedPrimary = ScriptedThrowBrain(script: [
            nil,
            .init(toolCalls: [.speak(callId: "recovered", lines: ["same target recovered"])]),
        ])
        #expect(driver.refreshBrainRouteClients(ConfiguredBrainRoute(targets: [
            ConfiguredBrainTarget(target: primaryTarget, brain: refreshedPrimary),
            ConfiguredBrainTarget(target: fallbackTarget, brain: fallback),
        ])))
        await successGate.release()

        #expect(await firstOutcome == .silentByModel)
        transcript.append(.init(speaker: .me, text: "one later temporary failure", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(refreshedPrimary.calls.count == 2)
        #expect(fallback.calls.isEmpty)
    }

    @Test func inFlightSuccessAcrossEffortReconfigurationResetsFailureSequence() async {
        let primaryTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let fallbackTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let successGate = AsyncGate()
        let originalPrimary = TwoFailuresThenGatedSuccessBrain(gate: successGate)
        let fallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "fallback", lines: ["should not advance"])]),
        ])
        let (driver, transcript) = makeRouteDriver([
            (primaryTarget, originalPrimary),
            (fallbackTarget, fallback),
        ])
        transcript.append(.init(speaker: .me, text: "complete across effort edit", at: 0))

        async let firstOutcome = driver.handleTrigger(.turnEnd)
        await successGate.waitUntilEntered()

        let reconfiguredPrimary = ScriptedThrowBrain(script: [
            nil,
            .init(toolCalls: [.speak(callId: "recovered", lines: ["same target recovered"])]),
        ])
        #expect(driver.reconfigureBrainRouteClients(ConfiguredBrainRoute(targets: [
            ConfiguredBrainTarget(target: primaryTarget, brain: reconfiguredPrimary),
            ConfiguredBrainTarget(target: fallbackTarget, brain: fallback),
        ])))
        await successGate.release()

        #expect(await firstOutcome == .silentByModel)
        transcript.append(.init(speaker: .me, text: "one later temporary failure", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(reconfiguredPrimary.calls.count == 2)
        #expect(fallback.calls.isEmpty)
    }

    @Test func inFlightFailureAcrossEffortReconfigurationCountsTowardRouteHealth() async {
        let primaryTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let fallbackTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let failureGate = AsyncGate()
        let originalPrimary = TwoFailuresThenGatedFailureBrain(gate: failureGate)
        let fallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "fallback", lines: ["advanced after third failure"])]),
        ])
        let (driver, transcript) = makeRouteDriver([
            (primaryTarget, originalPrimary),
            (fallbackTarget, fallback),
        ])
        transcript.append(.init(speaker: .me, text: "count the in-flight failure", at: 0))

        async let outcome = driver.handleTrigger(.turnEnd)
        await failureGate.waitUntilEntered()

        let reconfiguredPrimary = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "wrong", lines: ["failure was ignored"])]),
        ])
        #expect(driver.reconfigureBrainRouteClients(ConfiguredBrainRoute(targets: [
            ConfiguredBrainTarget(target: primaryTarget, brain: reconfiguredPrimary),
            ConfiguredBrainTarget(target: fallbackTarget, brain: fallback),
        ])))
        await failureGate.release()

        #expect(await outcome == .spoke)
        #expect(reconfiguredPrimary.calls.isEmpty)
        #expect(fallback.calls.count == 1)
    }

    @Test func refreshingClientsCannotDropOrRedirectCommittedExhaustion() async {
        let target = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let responseGate = AsyncGate()
        let failed = GatedThrowingBrain(
            gate: responseGate,
            error: BrainFailure(
                disposition: .permanent,
                detail: "terminal route failure"))
        let originalDelivery = RouteExhaustionRecorder()
        let refreshedDelivery = RouteExhaustionRecorder()
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default,
            transcript: transcript,
            route: ConfiguredBrainRoute(
                targets: [ConfiguredBrainTarget(target: target, brain: failed)],
                onExhausted: { originalDelivery.record(target: $0, failure: $1) }),
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })
        transcript.append(.init(speaker: .me, text: "deliver terminal state", at: 0))

        async let outcome = driver.handleTrigger(.turnEnd)
        await responseGate.waitUntilEntered()
        let mainActorEntered = DispatchSemaphore(value: 0)
        let releaseMainActor = DispatchSemaphore(value: 0)
        let mainActorBlocker = Task { @MainActor in
            blockMainActor(entered: mainActorEntered, release: releaseMainActor)
        }
        await waitForSemaphore(mainActorEntered)
        await responseGate.release()
        #expect(await waitUntilRouteReportsExhaustion(driver))

        let refreshed = ThrowingBrain(error: BrainFailure(
            disposition: .permanent,
            detail: "refreshed client should never run"))
        #expect(driver.refreshBrainRouteClients(ConfiguredBrainRoute(
            targets: [ConfiguredBrainTarget(target: target, brain: refreshed)],
            onExhausted: { refreshedDelivery.record(target: $0, failure: $1) })))

        releaseMainActor.signal()
        await mainActorBlocker.value
        #expect(await outcome == .brainError)
        #expect(originalDelivery.targets == [target])
        #expect(refreshedDelivery.targets.isEmpty)
        #expect(refreshed.callCount == 0)
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(originalDelivery.targets == [target])
    }

    @Test func explicitRouteUpdateSupersedesUndeliveredExhaustion() async {
        let failedTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let replacementTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let responseGate = AsyncGate()
        let failed = GatedThrowingBrain(
            gate: responseGate,
            error: BrainFailure(
                disposition: .permanent,
                detail: "old route failed"))
        let oldDelivery = RouteExhaustionRecorder()
        let replacement = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "replacement", lines: ["new route recovered"])]),
        ])
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default,
            transcript: transcript,
            route: ConfiguredBrainRoute(
                targets: [ConfiguredBrainTarget(target: failedTarget, brain: failed)],
                onExhausted: { oldDelivery.record(target: $0, failure: $1) }),
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })
        transcript.append(.init(speaker: .me, text: "preserve pending conversation", at: 0))

        async let outcome = driver.handleTrigger(.turnEnd)
        await responseGate.waitUntilEntered()
        let mainActorEntered = DispatchSemaphore(value: 0)
        let releaseMainActor = DispatchSemaphore(value: 0)
        let mainActorBlocker = Task { @MainActor in
            blockMainActor(entered: mainActorEntered, release: releaseMainActor)
        }
        await waitForSemaphore(mainActorEntered)
        await responseGate.release()
        #expect(await waitUntilRouteReportsExhaustion(driver))

        driver.updateBrainRoute(ConfiguredBrainRoute(targets: [
            ConfiguredBrainTarget(target: replacementTarget, brain: replacement),
        ]))
        releaseMainActor.signal()
        await mainActorBlocker.value

        #expect(await outcome == .spoke)
        #expect(oldDelivery.targets.isEmpty)
        #expect(replacement.calls.count == 1)
        #expect(replacement.calls[0].contains {
            ($0.text ?? "").contains("preserve pending conversation")
        })
    }

    @Test func allTargetsExhaustOnceAndStopTheConversation() async {
        let first = ThrowingBrain()
        let second = ThrowingBrain()
        let exhausted = RouteExhaustionRecorder()
        let (driver, transcript) = makeRouteDriver(
            [
                (BrainTarget(provider: .openAI, modelID: "gpt-5.5"), first),
                (BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5"), second),
            ],
            onExhausted: { exhausted.record(target: $0, failure: $1) })
        transcript.append(.init(speaker: .me, text: "bounded failure", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(first.callCount == 3)
        #expect(second.callCount == 3)
        #expect(exhausted.targets.map(\.provider) == [.claudeCode])
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(exhausted.targets.count == 1)
    }

    @Test func settingsRevisionDuringFinalFailureKeepsPendingWorkAlive() async {
        let failedTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let replacementTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let failed = ThrowingBrain(error: BrainFailure(
            disposition: .permanent,
            detail: "old route permanently failed"))
        let replacement = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "replacement", lines: ["new route recovered"])]),
        ])
        let replacementRoute = ConfiguredBrainRoute(targets: [
            ConfiguredBrainTarget(target: replacementTarget, brain: replacement),
        ])
        let holder = CoachDriverHolder()
        let oldRoute = ConfiguredBrainRoute(
            targets: [ConfiguredBrainTarget(target: failedTarget, brain: failed)],
            onExhausted: { _, _ in holder.updateRoute(replacementRoute) })
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default,
            transcript: transcript,
            route: oldRoute,
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })
        holder.install(driver)
        transcript.append(.init(speaker: .me, text: "do not orphan this transcript", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(failed.callCount == 1)
        #expect(replacement.calls.count == 1)
        #expect(replacement.calls[0].contains {
            ($0.text ?? "").contains("do not orphan this transcript")
        })
    }

    @Test func settingsRevisionDuringUnavailableFinalTargetReselectsImmediately() async {
        let unavailableTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let replacementTarget = BrainTarget(provider: .codexCLI, modelID: "gpt-5.6-sol")
        let replacement = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "replacement")]),
        ])
        let replacementRoute = ConfiguredBrainRoute(targets: [
            ConfiguredBrainTarget(target: replacementTarget, brain: replacement),
        ])
        let holder = CoachDriverHolder()
        let oldRoute = ConfiguredBrainRoute(
            targets: [
                ConfiguredBrainTarget(
                    unavailable: unavailableTarget,
                    detail: "Claude Code is signed out"),
            ],
            onExhausted: { _, _ in holder.updateRoute(replacementRoute) })
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default,
            transcript: transcript,
            route: oldRoute,
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })
        holder.install(driver)
        transcript.append(.init(speaker: .me, text: "use the replacement route", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        #expect(replacement.calls.count == 1)
        #expect(replacement.calls[0].contains {
            ($0.text ?? "").contains("use the replacement route")
        })
    }

    @Test func unavailableFallbackIsSkippedWithoutSyntheticAttempts() async {
        let primaryTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let unavailableTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let finalTarget = BrainTarget(provider: .codexCLI, modelID: "gpt-5.6-sol")
        let primary = ThrowingBrain(error: BrainFailure(
            disposition: .permanent,
            detail: "primary permanently failed"))
        let final = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "final", lines: ["final target"])]),
        ])
        let skipped = RouteTargetRecorder()
        let route = ConfiguredBrainRoute(
            targets: [
                ConfiguredBrainTarget(target: primaryTarget, brain: primary),
                ConfiguredBrainTarget(
                    unavailable: unavailableTarget,
                    detail: "Claude Code is signed out"),
                ConfiguredBrainTarget(target: finalTarget, brain: final),
            ],
            onSkipped: { skipped.record($0) })
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default,
            transcript: transcript,
            route: route,
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })
        transcript.append(.init(speaker: .me, text: "skip the unavailable row", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(primary.callCount == 1)
        #expect(final.calls.count == 1)
        #expect(skipped.targets == [unavailableTarget])
    }

    @Test func providerNeutralCaptureSurvivesButRawToolStateDoesNot() async {
        let primary = ScriptedThrowBrain(script: [
            .init(
                toolCalls: [.captureScreen(callId: "primary-capture")],
                rawToolCalls: [
                    RawToolCall(
                        id: "primary-capture",
                        name: "capture_screen",
                        argumentsJSON: "{}"),
                ],
                outputItemsJSON: [#"{"type":"reasoning","id":"secret"}"#]),
            nil,
            nil,
            nil,
        ])
        let fallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "fallback", lines: ["used observation"])]),
        ])
        let screen = FakeScreen(recognizedText: "let answer = 42")
        let (driver, transcript) = makeRouteDriver(
            [
                (BrainTarget(provider: .openAI, modelID: "gpt-5.5"), primary),
                (BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5"), fallback),
            ],
            screen: screen)
        transcript.append(.init(speaker: .me, text: "review visible code", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(screen.captureCount == 1)
        let fallbackRequest = fallback.calls[0]
        #expect(fallbackRequest.contains { $0.imageBase64JPEG == screen.payload })
        #expect(fallbackRequest.contains {
            ($0.text ?? "").contains("let answer = 42")
        })
        #expect(!fallbackRequest.contains { $0.role == .tool })
        #expect(!fallbackRequest.contains { $0.rawItemsJSON != nil })
        #expect(!fallbackRequest.contains { $0.toolCalls != nil })
    }

    @Test func automaticPendingAttemptWaitsForBothSpeakersToStop() async {
        let gate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock())
        driver.updateSpeechActivity(true, for: .me)
        driver.updateSpeechActivity(true, for: .them)
        transcript.append(.init(speaker: .me, text: "wait for quiet", at: 0))
        async let outcome = driver.handleTrigger(.turnEnd)
        await gate.waitUntilEntered()
        await gate.release()
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(brain.calls.count == 1)

        driver.updateSpeechActivity(false, for: .me)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(brain.calls.count == 1)

        driver.updateSpeechActivity(false, for: .them)
        #expect(await outcome == .spoke)
        #expect(brain.calls.count == 2)
    }

    @Test func lateManualHintInterruptsSpeechWaitAndJoinsPendingAttempt() async {
        let gate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let screen = FakeScreen()
        let (driver, transcript) = makeDriver(
            brain: brain,
            screen: screen,
            clock: ManualClock())
        driver.updateSpeechActivity(true, for: .them)
        transcript.append(.init(speaker: .me, text: "failed pending thought", at: 0))

        async let outcome = driver.handleTrigger(.turnEnd)
        await gate.waitUntilEntered()
        await gate.release()
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(brain.calls.count == 1)

        transcript.append(.init(speaker: .me, text: "latest words for the hint", at: 1))
        #expect(await driver.handleTrigger(.manualHint) == .busy)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(brain.calls.count == 2)

        // Cleanup also prevents a regression from parking the test forever after the expectation.
        driver.updateSpeechActivity(false, for: .them)
        #expect(await outcome == .spoke)
        #expect(screen.captureCount == 1)
        #expect(brain.calls[1].contains {
            ($0.text ?? "").contains("latest words for the hint")
        })
    }

    @Test func manualHintWakesFailedAttemptEvenWhileSpeechIsUnsettled() async {
        let gate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let (driver, transcript) = makeDriver(
            brain: brain,
            clock: ManualClock())
        driver.updateSpeechActivity(true, for: .them)
        transcript.append(.init(speaker: .me, text: "first attempt", at: 0))

        async let outcome = driver.handleTrigger(.turnEnd)
        await gate.waitUntilEntered()
        #expect(await driver.handleTrigger(.manualHint) == .busy)
        await gate.release()

        #expect(await outcome == .spoke)
        #expect(brain.calls.count == 2)
        driver.updateSpeechActivity(false, for: .them)
    }

    @Test func automaticRetryOfFailedManualHintWaitsForUnsettledSpeech() async {
        let gate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let (driver, _) = makeDriver(
            brain: brain,
            clock: ManualClock())
        driver.updateSpeechActivity(true, for: .them)

        async let outcome = driver.handleTrigger(.manualHint)
        await gate.waitUntilEntered()
        await gate.release()
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(brain.calls.count == 1)

        driver.updateSpeechActivity(false, for: .them)
        #expect(await outcome == .spoke)
        #expect(brain.calls.count == 2)
    }

    @Test func automaticManualHintAttemptDoesNotRecapture() async {
        let brain = TimeoutThenSpeakingBrain()
        let screen = FakeScreen()
        let (driver, _) = makeDriver(
            brain: brain,
            screen: screen,
            clock: ManualClock())

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(brain.calls.count == 2)
        #expect(screen.captureCount == 1)
        #expect(brain.calls[1].contains { $0.imageBase64JPEG == screen.payload })
    }

    @Test func indexDeltaSendsEachLineExactlyOnce() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
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

    /// Speech is not committed by a failed attempt, so the automatic fresh attempt rebuilds it.
    @Test func unsentSpeechIsRebuiltByAutomaticAttempt() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedThrowBrain(script: [
            nil,
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "important words", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        #expect(brain.calls.count == 2)
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
            .init(toolCalls: [.staySilent(callId: "quiet")]),
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
            .init(toolCalls: [.staySilent(callId: "quiet")]),
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
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
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
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
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

    /// Repeated incomplete attempts exhaust the only route target and never render partial output.
    @Test func incompleteResponsesExhaustTheOnlyTarget() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [], rawToolCalls: [],
                                                 incompleteReason: "max_output_tokens")])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(brain.calls.count == 3)
        #expect(overlay.rendered.isEmpty)
    }

    /// A model that repeatedly exhausts its tool loop eventually exhausts the route target.
    @Test func repeatedToolLoopExhaustionExhaustsTheOnlyTarget() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c")],
                  rawToolCalls: [RawToolCall(id: "c", name: "capture_screen", argumentsJSON: "{}")]),
        ])  // ScriptedBrain repeats the last response, so every iteration captures again
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "look at this code", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(brain.calls.count == 12)
        #expect(overlay.rendered.isEmpty)
    }

    @Test func freshAttemptCarriesOnlyTheLatestScreenObservation() async {
        let captures = (0..<8).map { index in
            BrainResponse(
                toolCalls: [.captureScreen(callId: "capture-\(index)")],
                rawToolCalls: [
                    RawToolCall(
                        id: "capture-\(index)",
                        name: "capture_screen",
                        argumentsJSON: "{}"),
                ])
        }
        let brain = ScriptedBrain(script: captures + [
            .init(toolCalls: [.speak(callId: "done", lines: ["bounded context"])]),
        ])
        let screen = FakeScreen(recognizedText: "latest visible code")
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(
            brain: brain,
            screen: screen,
            overlay: overlay,
            clock: ManualClock())
        transcript.append(.init(speaker: .me, text: "inspect this code", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(brain.calls.count == 9)
        #expect(brain.calls[8].count(where: { $0.imageBase64JPEG != nil }) == 1)
        #expect(brain.calls[8].count(where: {
            ($0.text ?? "").contains("latest visible code")
        }) == 1)
        #expect(overlay.rendered == [["bounded context"]])
    }

    @Test func brainErrorOutcome() async {
        let clock = ManualClock(now: 0)
        let brain = ThrowingBrain()
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
    }

    @Test func unknownBrainErrorExhaustsAfterThreeAttempts() async {
        let recorder = BrainFailureRecorder()
        let brain = ThrowingBrain()
        let (driver, transcript) = makeDriver(
            brain: brain, clock: ManualClock(now: 0),
            onBrainFailure: { recorder.record($0) }
        )
        transcript.append(.init(speaker: .me, text: "please help with this problem", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(recorder.messages == ["test brain failed"])
        #expect(recorder.failures.map(\.disposition) == [.temporary])

        transcript.append(.init(speaker: .me, text: "please try again", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(brain.callCount == 3)
    }

    @Test func cliWatchdogTimeoutSchedulesFreshAttemptWithoutNaturalTrigger() async {
        let recorder = BrainFailureRecorder()
        let brain = TimeoutThenSpeakingBrain()
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(
            brain: brain, brainProvider: .codexCLI, overlay: overlay,
            clock: ManualClock(now: 0),
            onBrainFailure: { recorder.record($0) }
        )
        transcript.append(.init(speaker: .me, text: "first question", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(recorder.failures.isEmpty)
        #expect(brain.calls.count == 2)
        #expect(brain.calls[1].contains {
            ($0.text ?? "").contains("first question")
        })
        #expect(overlay.rendered == [["recovered on the next turn"]])
    }

    @Test func pendingTriggerSurvivesTemporaryFailureAndRetriesUnsentSpeech() async {
        let gate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let overlay = FakeOverlay()
        let recorder = BrainFailureRecorder()
        let (driver, transcript) = makeDriver(
            brain: brain, brainProvider: .openAI, overlay: overlay,
            clock: ManualClock(now: 0),
            onBrainFailure: { recorder.record($0) }
        )
        transcript.append(.init(speaker: .me, text: "first question", at: 0))
        async let first = driver.handleTrigger(.turnEnd)
        await gate.waitUntilEntered()

        transcript.append(.init(speaker: .me, text: "follow-up while unavailable", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .busy)
        await gate.release()

        #expect(await first == .spoke)
        #expect(recorder.failures.isEmpty)
        #expect(brain.calls.count == 2)
        #expect(brain.calls[1].contains {
            ($0.text ?? "").contains("first question")
                && ($0.text ?? "").contains("follow-up while unavailable")
        })
        #expect(overlay.rendered == [["recovered pending turn"]])
    }

    @Test func naturalTriggerWakesAutomaticBackoffEarly() async {
        let brainGate = AsyncGate()
        let delayProbe = AutomaticDelayProbe()
        let brain = GatedFailureThenSpeakingBrain(gate: brainGate)
        let transcript = RollingTranscript()
        let target = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let driver = CoachDriver(
            config: .default,
            transcript: transcript,
            route: ConfiguredBrainRoute(targets: [
                ConfiguredBrainTarget(target: target, brain: brain),
            ]),
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in
                try await delayProbe.waitForCancellation()
            })
        transcript.append(.init(speaker: .me, text: "first pending thought", at: 0))
        async let first = driver.handleTrigger(.turnEnd)
        await brainGate.waitUntilEntered()
        await brainGate.release()
        await delayProbe.waitUntilEntered()

        transcript.append(.init(speaker: .me, text: "wake with this new thought", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .busy)

        #expect(await first == .spoke)
        #expect(brain.calls.count == 2)
        #expect(brain.calls[1].contains {
            ($0.text ?? "").contains("wake with this new thought")
        })
    }

    @Test func latestNaturalTriggerDescribesTheFreshAttempt() async {
        let gate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let (driver, transcript) = makeDriver(
            brain: brain,
            clock: ManualClock(now: 0))
        async let first = driver.handleTrigger(.silence(secondsQuiet: 30))
        await gate.waitUntilEntered()

        transcript.append(.init(speaker: .me, text: "new speech ended", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .busy)
        await gate.release()

        #expect(await first == .spoke)
        let retryUserText = brain.calls[1]
            .filter { $0.role == .user }
            .compactMap(\.text)
            .joined(separator: "\n")
        #expect(retryUserText.contains("new speech ended"))
        #expect(!retryUserText.contains("no speech for"))
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

/// Synchronous on purpose: it holds main-actor delivery at a deterministic point while the test
/// advances the provider revision from another executor.
@MainActor
private func blockMainActor(entered: DispatchSemaphore, release: DispatchSemaphore) {
    entered.signal()
    release.wait()
}

private func waitForSemaphore(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            semaphore.wait()
            continuation.resume()
        }
    }
}

/// The main actor is deliberately blocked before the route task starts. Yielding here lets that task
/// commit its lock-protected notice and park at the actor hop before the test refreshes clients.
private func allowPendingRouteDeliveryToReachMainActor() async {
    for _ in 0..<1_000 {
        await Task.yield()
    }
}

/// `@unchecked Sendable` is safe because `lock` guards the recorded route transitions.
private final class RouteTransitionRecorder: @unchecked Sendable {
    struct Event: Equatable {
        let from: BrainTarget
        let to: BrainTarget
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    var events: [Event] { lock.withLock { recorded } }
    func record(from: BrainTarget, to: BrainTarget) {
        lock.withLock { recorded.append(.init(from: from, to: to)) }
    }
}

/// `@unchecked Sendable` is safe because `lock` guards the recorded exhausted targets.
private final class RouteExhaustionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTargets: [BrainTarget] = []
    var targets: [BrainTarget] { lock.withLock { recordedTargets } }
    func record(target: BrainTarget, failure: BrainFailure) {
        _ = failure
        lock.withLock { recordedTargets.append(target) }
    }
}

/// `@unchecked Sendable` is safe because `lock` guards the recorded route targets.
private final class RouteTargetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BrainTarget] = []
    var targets: [BrainTarget] { lock.withLock { recorded } }
    func record(_ target: BrainTarget) {
        lock.withLock { recorded.append(target) }
    }
}

/// `@unchecked Sendable` is safe because `lock` guards the installed driver reference.
private final class CoachDriverHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var driver: CoachDriver?

    func install(_ driver: CoachDriver) {
        lock.withLock { self.driver = driver }
    }

    func updateRoute(_ route: ConfiguredBrainRoute) {
        lock.withLock { driver }?.updateBrainRoute(route)
    }
}

/// A brain that always throws, to exercise the `.brainError` outcome.
final class ThrowingBrain: BrainClient, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }

    init(error: Error = NSError(
        domain: "test", code: 401,
        userInfo: [NSLocalizedDescriptionKey: "test brain failed"])) {
        self.error = error
    }

    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        lock.withLock { calls += 1 }
        throw error
    }
}

/// A permanent failure parked behind an async gate so tests can commit route exhaustion while the
/// main actor is deliberately occupied. `lock` guards the observable call count.
private final class GatedThrowingBrain: BrainClient, @unchecked Sendable {
    private let gate: AsyncGate
    private let error: Error
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }

    init(gate: AsyncGate, error: Error) {
        self.gate = gate
        self.error = error
    }

    func respond(
        messages: [ChatMessage],
        tools: [ToolDef],
        toolChoice: ToolChoice
    ) async throws -> BrainResponse {
        _ = messages
        _ = tools
        _ = toolChoice
        lock.withLock { calls += 1 }
        await gate.enter()
        throw error
    }
}

/// Two temporary failures establish a near-exhausted sequence, then a successful third request
/// parks so the runtime clients can be refreshed before the completion is recorded.
private final class TwoFailuresThenGatedSuccessBrain: BrainClient, @unchecked Sendable {
    private let gate: AsyncGate
    private let lock = NSLock()
    private var calls = 0

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func respond(
        messages: [ChatMessage],
        tools: [ToolDef],
        toolChoice: ToolChoice
    ) async throws -> BrainResponse {
        _ = messages
        _ = tools
        _ = toolChoice
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call <= 2 {
            throw NSError(
                domain: "FutureProvider",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "temporary provider interruption"])
        }
        await gate.enter()
        return BrainResponse(toolCalls: [.staySilent(callId: "success")])
    }
}

/// Two temporary failures establish a near-exhausted sequence, then a third failure parks so a
/// same-topology effort reconfiguration can happen before that valid attempt outcome is recorded.
private final class TwoFailuresThenGatedFailureBrain: BrainClient, @unchecked Sendable {
    private let gate: AsyncGate
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func respond(
        messages: [ChatMessage],
        tools: [ToolDef],
        toolChoice: ToolChoice
    ) async throws -> BrainResponse {
        _ = messages
        _ = tools
        _ = toolChoice
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call == 3 {
            await gate.enter()
        }
        throw NSError(
            domain: "FutureProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "temporary provider interruption"])
    }
}

/// Lock-guarded because `CoachDriver`'s failure callback is `@Sendable`.
final class BrainFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BrainFailure] = []
    var failures: [BrainFailure] { lock.lock(); defer { lock.unlock() }; return recorded }
    var messages: [String] { failures.map(\.detail) }
    func record(_ failure: BrainFailure) { lock.lock(); recorded.append(failure); lock.unlock() }
}

/// The CLI watchdog misses the first turn, then the same conversation succeeds on the next trigger.
/// `@unchecked Sendable` is safe because `CoachDriver` awaits one `respond` call at a time, so this
/// test double's `calls` array is never accessed concurrently.
final class TimeoutThenSpeakingBrain: BrainClient, @unchecked Sendable {
    private(set) var calls: [[ChatMessage]] = []

    func respond(messages: [ChatMessage], tools: [ToolDef],
                 toolChoice: ToolChoice) async throws -> BrainResponse {
        calls.append(messages)
        if calls.count == 1 {
            throw NSError(
                domain: AgentCLIProcessRunner.errorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "codex timed out after 30s"]
            )
        }
        return BrainResponse(
            toolCalls: [.speak(callId: "recovered", lines: ["recovered on the next turn"])],
            rawToolCalls: [
                RawToolCall(
                    id: "recovered",
                    name: "speak",
                    argumentsJSON: #"{"lines":["recovered on the next turn"]}"#
                ),
            ]
        )
    }
}

/// A brain that parks inside `respond` until released, so a second concurrent trigger can be
/// observed hitting the single-in-flight guard.
final class GatedBrain: BrainClient, @unchecked Sendable {
    private let gate: AsyncGate
    private let script: [BrainResponse]
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    private func record() -> Int {
        lock.lock(); defer { lock.unlock() }
        let index = _callCount
        _callCount += 1
        return index
    }
    init(gate: AsyncGate, response: BrainResponse) { self.gate = gate; self.script = [response] }
    init(gate: AsyncGate, script: [BrainResponse]) { self.gate = gate; self.script = script }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        let index = record()
        await gate.enter()
        return script[min(index, script.count - 1)]
    }
}

/// A temporary first failure with a parked request, followed by success. This proves the driver's
/// coalesced trigger—not only a later external trigger—keeps the conversation alive.
/// `@unchecked Sendable` is safe because `recordedCalls` is always accessed through `NSLock`.
final class GatedFailureThenSpeakingBrain: BrainClient, @unchecked Sendable {
    private let gate: AsyncGate
    private let lock = NSLock()
    private var recordedCalls: [[ChatMessage]] = []
    var calls: [[ChatMessage]] { lock.withLock { recordedCalls } }

    init(gate: AsyncGate) { self.gate = gate }

    func respond(messages: [ChatMessage], tools: [ToolDef],
                 toolChoice: ToolChoice) async throws -> BrainResponse {
        let index = lock.withLock {
            recordedCalls.append(messages)
            return recordedCalls.count - 1
        }
        if index == 0 {
            await gate.enter()
            throw NSError(
                domain: "FutureProvider", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "temporary provider interruption"])
        }
        return BrainResponse(
            toolCalls: [.speak(callId: "recovered", lines: ["recovered pending turn"])],
            rawToolCalls: [
                RawToolCall(
                    id: "recovered", name: "speak",
                    argumentsJSON: #"{"lines":["recovered pending turn"]}"#),
            ])
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

private actor AutomaticDelayProbe {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForCancellation() async throws {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
}
