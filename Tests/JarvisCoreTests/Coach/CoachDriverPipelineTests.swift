import Foundation
import Testing
@testable import JarvisCore

/// Mock brain: replays a script of responses and records the messages + tool-choice it saw.
///
/// `@unchecked Sendable` is safe because every mutable property is accessed only under `lock`. The
/// lock is load-bearing rather than decorative: as a summarizer this double is driven from the
/// detached compaction task while the test polls its counters, so unsynchronized access would be a
/// genuine data race on the arrays' COW buffers.
final class ScriptedBrain: BrainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[ChatMessage]] = []
    private var _toolChoices: [ToolChoice] = []
    private var _requestContexts: [CoachingRequestContext?] = []
    private var _preparationCount = 0
    var calls: [[ChatMessage]] { lock.withLock { _calls } }
    var toolChoices: [ToolChoice] { lock.withLock { _toolChoices } }
    var requestContexts: [CoachingRequestContext?] { lock.withLock { _requestContexts } }
    var preparationCount: Int { lock.withLock { _preparationCount } }
    let script: [BrainResponse]
    init(script: [BrainResponse]) { self.script = script }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        let index = lock.withLock { () -> Int in
            _calls.append(messages)
            _toolChoices.append(toolChoice)
            _requestContexts.append(CoachingRequestAttribution.current)
            return _calls.count - 1
        }
        return script[min(index, script.count - 1)]
    }
    func prepare() { lock.withLock { _preparationCount += 1 } }
}

/// A brain whose per-call script can be a response OR a throw (nil), recording the messages it saw —
/// to verify what survives a failed turn and reaches the next one.
///
/// `@unchecked Sendable` is safe for the same reason as `ScriptedBrain`: all mutable state is
/// accessed under `lock`, which the detached compaction path makes necessary rather than optional.
final class ScriptedThrowBrain: BrainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[ChatMessage]] = []
    private var _requestContexts: [CoachingRequestContext?] = []
    private var idx = 0
    var calls: [[ChatMessage]] { lock.withLock { _calls } }
    var requestContexts: [CoachingRequestContext?] { lock.withLock { _requestContexts } }
    let script: [BrainResponse?]
    init(script: [BrainResponse?]) { self.script = script }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        let r = lock.withLock { () -> BrainResponse? in
            _calls.append(messages)
            _requestContexts.append(CoachingRequestAttribution.current)
            let reply = script[min(idx, script.count - 1)]; idx += 1
            return reply
        }
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
    func cancelCapture() {}
}

final class UnavailableScreen: ScreenCapturing, @unchecked Sendable {
    func capture() -> ScreenSnapshot? { nil }
    func cancelCapture() {}
}

/// A screen whose `capture()` parks until released. Cancellation releases it through the same
/// adapter boundary production uses to terminate `screencapture`.
final class GatedScreen: ScreenCapturing, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private(set) var captureCount = 0
    private(set) var cancelCount = 0
    let payload: String
    init(payload: String = "ZmFrZS1qcGVn") { self.payload = payload }
    func capture() -> ScreenSnapshot? {
        captureCount += 1
        entered.signal()
        release.wait()
        return ScreenSnapshot(imageBase64: payload)
    }
    func cancelCapture() {
        cancelCount += 1
        release.signal()
    }
}

/// A cancelled capture acknowledges the stop request but holds its final helper/file cleanup until
/// the test releases it. This distinguishes requesting cancellation from awaiting cleanup.
final class HeldCleanupScreen: ScreenCapturing, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let cancellationRequested = DispatchSemaphore(value: 0)
    let allowCleanup = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedCaptureCount = 0
    private var storedCancelCount = 0

    var captureCount: Int {
        lock.withLock { storedCaptureCount }
    }

    var cancelCount: Int {
        lock.withLock { storedCancelCount }
    }

    func capture() -> ScreenSnapshot? {
        lock.withLock { storedCaptureCount += 1 }
        entered.signal()
        allowCleanup.wait()
        return nil
    }

    func cancelCapture() {
        lock.withLock { storedCancelCount += 1 }
        cancellationRequested.signal()
    }
}

private struct FinishTrackingBrain: BrainClient {
    let conversation: FinishTrackingConversation

    init(finished: DispatchSemaphore, script: [BrainResponse]) {
        self.conversation = FinishTrackingConversation(finished: finished, script: script)
    }

    func respond(
        messages: [ChatMessage],
        tools: [ToolDef],
        toolChoice: ToolChoice
    ) async throws -> BrainResponse {
        try await conversation.respond(
            messages: messages, tools: tools, toolChoice: toolChoice)
    }

    func makeConversation() async throws -> any BrainConversation {
        conversation
    }

    func recordedCallCount() async -> Int {
        await conversation.callCount
    }
}

private actor FinishTrackingConversation: BrainConversation {
    let finished: DispatchSemaphore
    let script: [BrainResponse]
    private(set) var callCount = 0

    init(finished: DispatchSemaphore, script: [BrainResponse]) {
        self.finished = finished
        self.script = script
    }

    func respond(
        messages: [ChatMessage],
        tools: [ToolDef],
        toolChoice: ToolChoice
    ) async throws -> BrainResponse {
        _ = messages
        _ = tools
        _ = toolChoice
        let response = script[min(callCount, script.count - 1)]
        callCount += 1
        return response
    }

    func finish() async {
        finished.signal()
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

// Each test that reads activity owns the `ActivityLog` it hands its driver, so a snapshot holds
// that test's rows and nothing else. Being the only suite that *enables* the shared log was never
// enough on its own: every driver alive anywhere in the process appended to whichever log happened
// to be enabled, so a peer suite's rows landed in these snapshots.
@Suite struct CoachDriverPipelineTests {
    private func makeDriver(activityLog: ActivityLog = ActivityLog(),
                            brain: BrainClient, brainProvider: BrainProvider? = nil,
                            summarizer: BrainClient? = nil,
                            screen: ScreenCapturing = FakeScreen(),
                            overlay: OverlayRendering = FakeOverlay(),
                            clock: Clock, config: Config = .default,
                            coachingAttempts: (any CoachingAttemptAuditing)? = nil,
                            automaticAttemptDelay: @escaping CoachDriver.AutomaticAttemptDelay = { _ in },
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
            coachingAttempts: coachingAttempts,
            automaticAttemptDelay: automaticAttemptDelay,
            activityLog: activityLog
        )
        return (driver, transcript)
    }

    private func makeRouteDriver(
        _ targets: [(BrainTarget, BrainClient)],
        screen: ScreenCapturing = FakeScreen(),
        overlay: OverlayRendering = FakeOverlay(),
        onAdvanced: (@Sendable (BrainTarget, BrainTarget) -> Void)? = nil,
        onSkipped: (@Sendable (BrainTarget) -> Void)? = nil,
        onExhausted: (@MainActor @Sendable (BrainTarget, BrainFailure) -> Void)? = nil,
        activityLog: ActivityLog = ActivityLog()
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
                automaticAttemptDelay: { _ in },
                activityLog: activityLog),
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
        #expect(brain.requestContexts.compactMap { $0 }.map(\.phase) == [
            .initial, .captureScreenContinuation,
        ])
        #expect(Set(brain.requestContexts.compactMap { $0 }.map(\.attemptID)).count == 1)
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
    /// This drives a test-owned `ActivityLog` through the real typed activity-event path.
    @Test func screenshotLandsInActivityLogAsValidJpeg() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-e2e-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let activityLog = ActivityLog()
        defer { activityLog.disable(); try? FileManager.default.removeItem(at: dir) }
        activityLog.enable(directory: dir)

        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c1")],
                  rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.speak(callId: "s1", lines: ["Watch the off-by-one there."])],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                             argumentsJSON: #"{"lines":["Watch the off-by-one there."]}"#)]),
        ])
        let screen = FakeScreen(payload: TestFixtures.tinyJpegBase64)   // a real JPEG, like screencapture
        let (driver, transcript) = makeDriver(
            activityLog: activityLog, brain: brain, screen: screen, clock: clock)
        transcript.append(.init(speaker: .me, text: "here's my solution", at: 100))

        await driver.handleTrigger(.turnEnd)

        // attach() runs on the activity log's serial queue (a sync barrier after the async record()
        // calls), so everything is persisted before we assert.
        _ = activityLog.attach { _ in }
        let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        #expect(jsonl.contains("looking at your screen"))   // the capture line
        #expect(jsonl.contains("shot-"))                     // line references the saved screenshot

        // Match the fixture byte for byte rather than taking the first valid JPEG, so this asserts
        // on the image the capture actually persisted. This proves the capture
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
    /// Drives a test-owned `ActivityLog` like the screenshot e2e above.
    @Test func manualHintTriggerAndPrefilledMessageLandInActivityLog() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-hintlog-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let activityLog = ActivityLog()
        defer { activityLog.disable(); try? FileManager.default.removeItem(at: dir) }
        activityLog.enable(directory: dir)

        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["use a hash map"])])])
        let (driver, transcript) = makeDriver(
            activityLog: activityLog, brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "stuck on two-sum", at: 100))

        await driver.handleTrigger(.manualHint)

        _ = activityLog.attach { _ in }   // sync barrier: all async record()s have landed
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
        let activityLog = ActivityLog()
        defer { activityLog.disable(); try? FileManager.default.removeItem(at: dir) }
        JarvisLog.enableFileLogging(directory: dir)
        activityLog.enable(directory: dir)

        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "s", lines: ["activity-boundary-tip-417"])])
        ])
        let (driver, _) = makeDriver(
            activityLog: activityLog, brain: brain, clock: ManualClock(now: 417))

        #expect(await driver.handleTrigger(.silence(secondsQuiet: 417)) == .spoke)

        _ = activityLog.attach { _ in }   // sync barrier: all async records have landed
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
        let activityLog = ActivityLog()
        defer { activityLog.disable(); try? FileManager.default.removeItem(at: dir) }
        activityLog.enable(directory: dir)

        let brain = ScriptedThrowBrain(script: [
            nil,
            nil,
            .init(toolCalls: [.speak(callId: "recovered", lines: ["recovered coaching"])]),
        ])
        let (driver, transcript) = makeDriver(
            activityLog: activityLog, brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "keep listening after failures", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        let snapshot = activityLog.attach { _ in }
        // Anchor on the recovery row and inspect the two failures before it: this asserts the
        // ordering around the recovery rather than the log's total length.
        let recoveryIndex = try #require(
            snapshot.rows.firstIndex { $0.contains("recovered coaching") })
        let failureRows = snapshot.rows[..<recoveryIndex].filter {
            $0.contains("couldn't finish the response")
        }
        #expect(failureRows.count >= 2)
        let relevantFailures = failureRows.suffix(2)
        for row in relevantFailures {
            #expect(row.contains("retrying"))
            #expect(row.contains("listening continues"))
        }
        let recovery = snapshot.rows[recoveryIndex]
        #expect(recovery.contains("recovered coaching"))
        #expect(!(relevantFailures + [recovery]).joined().contains("test"))
    }

    /// Stop cancelling a turn while the screenshot is being captured must cancel the capture edge,
    /// wait for its cleanup, then release the provider conversation without emitting or following up.
    @Test func cancelDuringCaptureAbortsBeforeEmitting() async {
        let clock = ManualClock(now: 0)
        let finished = DispatchSemaphore(value: 0)
        let brain = FinishTrackingBrain(finished: finished, script: [
            .init(toolCalls: [.captureScreen(callId: "c")],
                  rawToolCalls: [RawToolCall(id: "c", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.speak(callId: "s", lines: ["stale tip from the stopped run"])]),
        ])
        let screen = HeldCleanupScreen()
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, screen: screen, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "here is my code", at: 0))

        let task = Task { await driver.handleTrigger(.turnEnd) }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { screen.entered.wait(); cont.resume() }   // capture in flight
        }
        task.cancel()                                         // Stop requests capture cancellation
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                screen.cancellationRequested.wait()
                cont.resume()
            }
        }
        let releasedBeforeCleanup = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: finished.wait(timeout: .now() + 0.1) == .success)
            }
        }
        #expect(!releasedBeforeCleanup)

        screen.allowCleanup.signal()
        let releasedAfterCaptureCleanup = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: finished.wait(timeout: .now() + 1) == .success)
            }
        }
        #expect(releasedAfterCaptureCleanup)

        #expect(await task.value == .cancelled)
        #expect(screen.captureCount == 1)        // captured once...
        #expect(screen.cancelCount == 1)         // ...and cancelled through the capture adapter
        #expect(overlay.rendered.isEmpty)        // ...but never rendered a tip after Stop
        #expect(await brain.recordedCallCount() == 1) // and never looped back with the image
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
        let activityLog = ActivityLog()
        defer { activityLog.disable(); try? FileManager.default.removeItem(at: dir) }
        activityLog.enable(directory: dir)

        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")],
                  rawToolCalls: [RawToolCall(id: "quiet", name: "stay_silent", argumentsJSON: "{}")])
        ])
        let (driver, transcript) = makeDriver(
            activityLog: activityLog, brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "thinking about the columns", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)

        let snapshot = activityLog.attach { _ in }
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows[0].contains("stayed silent"))
    }

    /// A failed `capture_screen` records the action and fixed recovery guidance before the model
    /// makes its terminal choice.
    @Test func failedScreenActionAndStaySilentBothLandInActivityLog() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-failed-screen-action-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let activityLog = ActivityLog()
        defer { activityLog.disable(); try? FileManager.default.removeItem(at: dir) }
        activityLog.enable(directory: dir)

        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "capture")],
                  rawToolCalls: [RawToolCall(id: "capture", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.staySilent(callId: "quiet")],
                  rawToolCalls: [RawToolCall(id: "quiet", name: "stay_silent", argumentsJSON: "{}")]),
        ])
        let (driver, transcript) = makeDriver(
            activityLog: activityLog, brain: brain, screen: UnavailableScreen(),
            clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "look at this", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)

        let snapshot = activityLog.attach { _ in }
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

    // MARK: - The substance gate: clear hesitation sounds never buy a brain request

    /// A turn-end whose whole delta is clear hesitation sounds — from EITHER speaker — is skipped
    /// without a request: those sounds can't produce a tip, and the call would only re-bill context.
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

    @Test func fillerOnlySkipIsPersistedWithoutAProviderCall() async throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let attempts = await FileSessionAudit.readyForTesting(directory: dir)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "unused")]),
        ])
        let (driver, transcript) = makeDriver(
            brain: brain,
            clock: ManualClock(now: 0),
            coachingAttempts: attempts)
        transcript.append(.init(speaker: .them, text: "Uh. Hmm.", at: 1))

        #expect(await driver.handleTrigger(.turnEnd) == .skippedFillerOnly)
        #expect(brain.calls.isEmpty)
        _ = await attempts.closeForTesting()
        let jsonl = try String(
            contentsOf: dir.appendingPathComponent(FileSessionAudit.coachingAttemptsFilename),
            encoding: .utf8)
        #expect(jsonl.contains(#""event":"started""#))
        #expect(jsonl.contains(#""classification":"composite_filler""#))
        #expect(jsonl.contains(#""brain_facing":false"#))
        #expect(jsonl.contains(#""terminal":"skipped_filler""#))
    }

    /// Several clear hesitation sounds in one transcription completion are still one filler-only
    /// turn and do not buy a request.
    @Test func compositeFillerTurnEndSkipsTheBrain() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "Uh. Hmm. Oh, oh.", at: 1))

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

    /// Context-dependent short replies remain substantive for either speaker, including when the
    /// transcriber combines one with a clear hesitation sound.
    @Test func contextDependentTerseRepliesReachTheBrainForEitherSpeaker() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .them, text: "No. Okay.", at: 1))
        transcript.append(.init(speaker: .me, text: "Yes. Hmm.", at: 2))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        #expect(brain.calls.count == 1)
        let userText = brain.calls[0].filter { $0.role == .user }.compactMap(\.text)
            .joined(separator: " ")
        #expect(userText.contains("No. Okay."))
        #expect(userText.contains("Yes. Hmm."))
    }

    /// Uppercase tokens that spell like hesitation sounds can be variables or acronyms. They must
    /// reach the brain rather than being permanently consumed at the transcript boundary.
    @Test func acronymLikeShortUtterancesReachTheBrain() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .them, text: "ER", at: 1))
        transcript.append(.init(speaker: .me, text: "M", at: 2))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        #expect(brain.calls.count == 1)
        let userText = brain.calls[0].filter { $0.role == .user }.compactMap(\.text)
            .joined(separator: " ")
        #expect(userText.contains("[00:01] them: ER"))
        #expect(userText.contains("[00:02] me: M"))
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

    /// Activity has already retained finalized speech, so a locally skipped filler line is consumed
    /// and does not inflate the next substantive request.
    @Test func skippedFillerDoesNotRideAlongOnTheNextTurn() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .them, text: "嗯", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .skippedFillerOnly)
        transcript.append(.init(speaker: .me, text: "I'd check both neighbors at that height", at: 5))
        await driver.handleTrigger(.turnEnd)
        let userText = brain.calls[0].filter { $0.role == .user }.compactMap(\.text)
            .joined(separator: " ")
        #expect(!userText.contains("嗯"))
        #expect(userText.contains("I'd check both neighbors at that height"))
    }

    /// A clear hesitation sound beside real speech remains in Activity but is removed from input.
    @Test func mixedDeltaSendsOnlySubstantiveLines() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "Hmm.", at: 1))
        transcript.append(.init(speaker: .them, text: "How would you test that?", at: 2))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        let userText = brain.calls[0].filter { $0.role == .user }.compactMap(\.text)
            .joined(separator: " ")
        #expect(!userText.contains("Hmm."))
        #expect(userText.contains("How would you test that?"))
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

    /// A filler wake after a failed silence attempt has no new value to send. It consumes the
    /// transcript boundary instead of starting a fresh provider request with an empty user message.
    @Test func fillerWakeAfterFailedSilenceSkipsEmptyFreshAttempt() async {
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

        #expect(await outcome == .skippedFillerOnly)
        #expect(brain.calls.count == 1)
        #expect(overlay.rendered.isEmpty)
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

        let refreshedPrimary = ThrowingBrain()
        let refreshedFallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "refreshed", lines: ["new key works"])]),
        ])
        #expect(driver.refreshBrainRouteClients(ConfiguredBrainRoute(targets: [
            ConfiguredBrainTarget(target: primaryTarget, brain: refreshedPrimary),
            ConfiguredBrainTarget(target: fallbackTarget, brain: refreshedFallback),
        ])))

        transcript.append(.init(speaker: .me, text: "continue on fallback", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(refreshedPrimary.callCount == 0)
        #expect(refreshedPrimary.terminationCount == 1)
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

        let reconfiguredPrimary = ThrowingBrain()
        let reconfiguredFallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "effort", lines: ["new effort"])]),
        ])
        #expect(driver.reconfigureBrainRouteClients(ConfiguredBrainRoute(targets: [
            ConfiguredBrainTarget(target: primaryTarget, brain: reconfiguredPrimary),
            ConfiguredBrainTarget(target: fallbackTarget, brain: reconfiguredFallback),
        ])))

        transcript.append(.init(speaker: .me, text: "continue on fallback", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(reconfiguredPrimary.callCount == 0)
        #expect(reconfiguredPrimary.preparationCount == 0)
        #expect(reconfiguredPrimary.terminationCount == 1)
        #expect(reconfiguredFallback.calls.count == 1)
        #expect(reconfiguredFallback.preparationCount == 1)
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

    /// Regression: a route notice belongs to the callback it was committed against. A client
    /// refresh landing after the commit but before the delivery crosses to the main actor may
    /// neither redirect the notice onto the replacement callback nor drop it.
    ///
    /// The commit and the delivery are driven directly because that is the only way to sit inside
    /// that window. Under `handleTrigger` the two are adjacent within a single task with nothing
    /// observable in between, so a test can only guess when the commit landed — and a guess that
    /// lands early silently asserts nothing while a guess that lands late fails for no reason.
    @Test func aCommittedSkipIsDeliveredToTheCallbackItWasCommittedAgainst() async throws {
        let unavailableTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let availableTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let originalSkip = RouteTargetRecorder()
        let refreshedSkip = RouteTargetRecorder()
        let driver = CoachDriver(
            config: .default,
            transcript: RollingTranscript(),
            route: ConfiguredBrainRoute(
                targets: [
                    ConfiguredBrainTarget(
                        unavailable: unavailableTarget,
                        detail: "Claude Code is signed out"),
                    ConfiguredBrainTarget(
                        target: availableTarget,
                        brain: ScriptedBrain(script: [
                            .init(toolCalls: [.staySilent(callId: "old-client")]),
                        ])),
                ],
                onSkipped: { originalSkip.record($0) }),
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })

        let committed = try #require(driver.takeBrainSelectionStep().skipped)
        #expect(driver.refreshBrainRouteClients(ConfiguredBrainRoute(
            targets: [
                ConfiguredBrainTarget(
                    unavailable: unavailableTarget,
                    detail: "Claude Code is still signed out"),
                ConfiguredBrainTarget(
                    target: availableTarget,
                    brain: ScriptedBrain(script: [
                        .init(toolCalls: [.staySilent(callId: "new-client")]),
                    ])),
            ],
            onSkipped: { refreshedSkip.record($0) })))
        await driver.deliverRouteSkip(committed)

        #expect(originalSkip.targets == [unavailableTarget])
        #expect(refreshedSkip.targets.isEmpty)
    }

    /// The paired transition commits the target the route left behind together with the callback
    /// live at that moment, so the same refresh window must not redirect or drop it either.
    @Test func aCommittedAdvanceIsDeliveredToTheCallbackItWasCommittedAgainst() async throws {
        let unavailableTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let availableTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let originalAdvance = RouteTransitionRecorder()
        let refreshedAdvance = RouteTransitionRecorder()
        let driver = CoachDriver(
            config: .default,
            transcript: RollingTranscript(),
            route: ConfiguredBrainRoute(
                targets: [
                    ConfiguredBrainTarget(
                        unavailable: unavailableTarget,
                        detail: "Claude Code is signed out"),
                    ConfiguredBrainTarget(
                        target: availableTarget,
                        brain: ScriptedBrain(script: [
                            .init(toolCalls: [.staySilent(callId: "old-client")]),
                        ])),
                ],
                onAdvanced: { originalAdvance.record(from: $0, to: $1) }),
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })

        // The first step skips the unavailable head and remembers where the route came from; the
        // second commits the transition onto the target that can actually run.
        _ = driver.takeBrainSelectionStep()
        let committed = try #require(driver.takeBrainSelectionStep().advanced)
        #expect(driver.refreshBrainRouteClients(ConfiguredBrainRoute(
            targets: [
                ConfiguredBrainTarget(
                    unavailable: unavailableTarget,
                    detail: "Claude Code is still signed out"),
                ConfiguredBrainTarget(
                    target: availableTarget,
                    brain: ScriptedBrain(script: [
                        .init(toolCalls: [.staySilent(callId: "new-client")]),
                    ])),
            ],
            onAdvanced: { refreshedAdvance.record(from: $0, to: $1) })))
        await driver.deliverRouteAdvance(committed)

        #expect(originalAdvance.events == [
            .init(from: unavailableTarget, to: availableTarget),
        ])
        #expect(refreshedAdvance.events.isEmpty)
    }

    /// The other half of the contract, driven end to end: a refresh raised from inside the notice
    /// itself must not repeat that notice on the replacement callback, and the attempt that
    /// follows must run on the replacement client rather than the one the route started with.
    @Test func refreshingClientsDuringASkipRetargetsOnlyTheFollowingAttempt() async {
        let unavailableTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let availableTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let originalAvailable = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "old-client")]),
        ])
        let refreshedAvailable = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "new-client")]),
        ])
        let originalSkip = RouteTargetRecorder()
        let refreshedSkip = RouteTargetRecorder()
        let holder = CoachDriverHolder()
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
                onSkipped: { target in
                    originalSkip.record(target)
                    holder.refreshClients(ConfiguredBrainRoute(
                        targets: [
                            ConfiguredBrainTarget(
                                unavailable: unavailableTarget,
                                detail: "Claude Code is still signed out"),
                            ConfiguredBrainTarget(
                                target: availableTarget,
                                brain: refreshedAvailable),
                        ],
                        onSkipped: { refreshedSkip.record($0) }))
                }),
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })
        holder.install(driver)
        transcript.append(.init(speaker: .me, text: "skip without losing the notice", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        #expect(originalSkip.targets == [unavailableTarget])
        #expect(refreshedSkip.targets.isEmpty)
        #expect(originalAvailable.calls.isEmpty)
        #expect(refreshedAvailable.calls.count == 1)
    }

    /// The same shape around a transition. The selection committed alongside the advance is stale
    /// once the refresh bumps the route revision, so it must be discarded and re-taken against the
    /// replacement client instead of running the client the route had already chosen.
    @Test func refreshingClientsDuringAnAdvanceRetargetsOnlyTheFollowingAttempt() async {
        let unavailableTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let availableTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let originalAvailable = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "old-client")]),
        ])
        let refreshedAvailable = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "new-client")]),
        ])
        let originalAdvance = RouteTransitionRecorder()
        let refreshedAdvance = RouteTransitionRecorder()
        let holder = CoachDriverHolder()
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
                onAdvanced: { previous, current in
                    originalAdvance.record(from: previous, to: current)
                    holder.refreshClients(ConfiguredBrainRoute(
                        targets: [
                            ConfiguredBrainTarget(
                                unavailable: unavailableTarget,
                                detail: "Claude Code is still signed out"),
                            ConfiguredBrainTarget(
                                target: availableTarget,
                                brain: refreshedAvailable),
                        ],
                        onAdvanced: { refreshedAdvance.record(from: $0, to: $1) }))
                }),
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })
        holder.install(driver)
        transcript.append(.init(speaker: .me, text: "advance without losing the notice", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        #expect(originalAdvance.events == [
            .init(from: unavailableTarget, to: availableTarget),
        ])
        #expect(refreshedAdvance.events.isEmpty)
        #expect(originalAvailable.calls.isEmpty)
        #expect(refreshedAvailable.calls.count == 1)
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
        #expect(first.terminationCount == 1)
        #expect(second.terminationCount == 1)
        #expect(exhausted.targets.map(\.provider) == [.claudeCode])
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(exhausted.targets.count == 1)
        #expect(first.terminationCount == 1)
        #expect(second.terminationCount == 1)
    }

    @Test func advancingTheRouteTerminatesTheExhaustedCoachAndSummarizer() async {
        let primaryTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
        let fallbackTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let permanent = BrainFailure(
            disposition: .permanent,
            detail: "provider boundary is permanently unavailable")
        let primary = ThrowingBrain(error: permanent)
        let summarizer = ThrowingBrain()
        let fallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "fallback", lines: ["recovered"])]),
        ])
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default,
            transcript: transcript,
            route: ConfiguredBrainRoute(targets: [
                ConfiguredBrainTarget(
                    target: primaryTarget,
                    brain: primary,
                    summarizer: summarizer),
                ConfiguredBrainTarget(target: fallbackTarget, brain: fallback),
            ]),
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })
        transcript.append(.init(speaker: .me, text: "advance cleanly", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(primary.terminationCount == 1)
        #expect(summarizer.terminationCount == 1)
        #expect(fallback.calls.count == 1)
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

    /// A completed screen observation is useful context for a fresh attempt even when the only new
    /// speech is filler. Send the observation directly: do not recapture, replay raw tool state, or
    /// manufacture an empty/synthetic speech message.
    @Test func savedObservationStartsFreshAttemptWithoutEmptySpeech() async throws {
        let gate = AsyncGate()
        let brain = CaptureThenGatedFailureThenSpeakingBrain(gate: gate)
        let screen = FakeScreen(recognizedText: "let answer = 42")
        let (driver, transcript) = makeDriver(
            brain: brain,
            screen: screen,
            clock: ManualClock())

        let outcome = Task {
            await turnOutcomeBeforeTimeout {
                await driver.handleTrigger(.silence(secondsQuiet: 30))
            }
        }
        defer { outcome.cancel() }
        #expect(await waitUntilAsync { await gate.hasEntered })
        transcript.append(.init(speaker: .them, text: "Hmm.", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .busy)
        await gate.release()

        #expect(await outcome.value == .spoke)
        #expect(screen.captureCount == 1)
        try #require(brain.calls.count == 3)
        let freshRequest = brain.calls[2]
        #expect(!freshRequest.contains { $0.role == .user && $0.text == "" })
        #expect(!freshRequest.contains { ($0.text ?? "").contains("Hmm.") })
        #expect(freshRequest.contains { $0.imageBase64JPEG == screen.payload })
        #expect(freshRequest.contains { ($0.text ?? "").contains("let answer = 42") })
        #expect(!freshRequest.contains { $0.role == .tool })
        #expect(!freshRequest.contains { $0.rawItemsJSON != nil })
        #expect(!freshRequest.contains { $0.toolCalls != nil })
    }

    @Test func initialAutomaticAttemptWaitsForSettlementAndOrdersLateEarlierSpeech() async throws {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock())
        driver.updateTranscriptionWork(true, for: .them)
        transcript.append(.init(speaker: .me, text: "Yep.", at: 20))

        let outcome = Task {
            await turnOutcomeBeforeTimeout {
                await driver.handleTrigger(.turnEnd)
            }
        }
        defer {
            outcome.cancel()
            driver.updateTranscriptionWork(false, for: .them)
        }

        #expect(!(await waitUntil { !brain.calls.isEmpty }))
        transcript.append(.init(speaker: .them, text: "Did you see the pop-up?", at: 10))
        driver.updateTranscriptionWork(false, for: .them)

        #expect(await outcome.value == .silentByModel)
        let request = try #require(brain.calls.first)
        let userText = request.compactMap(\.text).joined(separator: "\n")
        let question = try #require(userText.range(of: "them: Did you see the pop-up?"))
        let reply = try #require(userText.range(of: "me: Yep."))
        #expect(question.lowerBound < reply.lowerBound)
    }

    @Test func queuedAutomaticAttemptAlsoWaitsForSettlement() async throws {
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, script: [
            .init(toolCalls: [.staySilent(callId: "first")]),
            .init(toolCalls: [.staySilent(callId: "second")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock())
        transcript.append(.init(speaker: .me, text: "First complete turn.", at: 1))

        let outcome = Task {
            await turnOutcomeBeforeTimeout {
                await driver.handleTrigger(.turnEnd)
            }
        }
        defer {
            outcome.cancel()
            driver.updateTranscriptionWork(false, for: .them)
        }
        await gate.waitUntilEntered()

        driver.updateTranscriptionWork(true, for: .them)
        transcript.append(.init(speaker: .me, text: "Yep.", at: 20))
        #expect(await driver.handleTrigger(.turnEnd) == .busy)
        await gate.release()

        #expect(!(await waitUntil { brain.callCount == 2 }))
        transcript.append(.init(speaker: .them, text: "Did you see the pop-up?", at: 10))
        driver.updateTranscriptionWork(false, for: .them)

        #expect(await outcome.value == .silentByModel)
        let request = try #require(brain.calls.last)
        let userText = request.compactMap(\.text).joined(separator: "\n")
        let question = try #require(userText.range(of: "them: Did you see the pop-up?"))
        let reply = try #require(userText.range(of: "me: Yep."))
        #expect(question.lowerBound < reply.lowerBound)
    }

    @Test func automaticPendingAttemptWaitsForBothSpeakersToStop() async {
        let gate = AsyncGate()
        let delayGate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let (driver, transcript) = makeDriver(
            brain: brain,
            clock: ManualClock(),
            automaticAttemptDelay: { _ in await delayGate.enter() })
        transcript.append(.init(speaker: .me, text: "wait for quiet", at: 0))
        let outcome = Task {
            await turnOutcomeBeforeTimeout {
                await driver.handleTrigger(.turnEnd)
            }
        }
        defer { outcome.cancel() }
        await gate.waitUntilEntered()
        driver.updateTranscriptionWork(true, for: .me)
        driver.updateTranscriptionWork(true, for: .them)
        await gate.release()
        #expect(await waitUntilAsync { await delayGate.hasEntered })
        #expect(brain.calls.count == 1)

        driver.updateTranscriptionWork(false, for: .me)
        #expect(brain.calls.count == 1)

        await delayGate.release()
        // Give a broken retry a bounded chance to make the forbidden second call. While `.them`
        // remains active, the pending attempt must stay parked instead.
        #expect(!(await waitUntil {
            brain.calls.count == 2
        }))
        driver.updateTranscriptionWork(false, for: .them)
        #expect(await outcome.value == .spoke)
        #expect(brain.calls.count == 2)
    }

    @Test func lateManualHintInterruptsSpeechWaitAndJoinsPendingAttempt() async throws {
        let gate = AsyncGate()
        let delayProbe = AutomaticDelayProbe()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let screen = FakeScreen()
        let (driver, transcript) = makeDriver(
            brain: brain,
            screen: screen,
            clock: ManualClock(),
            automaticAttemptDelay: { _ in
                try await delayProbe.waitForCancellation()
            })
        transcript.append(.init(speaker: .me, text: "failed pending thought", at: 0))

        let outcome = Task {
            await turnOutcomeBeforeTimeout {
                await driver.handleTrigger(.turnEnd)
            }
        }
        defer {
            outcome.cancel()
            driver.updateTranscriptionWork(false, for: .them)
        }
        await gate.waitUntilEntered()
        driver.updateTranscriptionWork(true, for: .them)
        await gate.release()
        #expect(await waitUntilAsync { await delayProbe.hasEntered })
        #expect(brain.calls.count == 1)

        transcript.append(.init(speaker: .me, text: "latest words for the hint", at: 1))
        #expect(await driver.handleTrigger(.manualHint) == .busy)
        #expect(await outcome.value == .spoke)
        try #require(brain.calls.count == 2)
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
        transcript.append(.init(speaker: .me, text: "first attempt", at: 0))

        async let outcome = driver.handleTrigger(.turnEnd)
        await gate.waitUntilEntered()
        driver.updateTranscriptionWork(true, for: .them)
        #expect(await driver.handleTrigger(.manualHint) == .busy)
        await gate.release()

        #expect(await outcome == .spoke)
        #expect(brain.calls.count == 2)
        driver.updateTranscriptionWork(false, for: .them)
    }

    @Test func automaticRetryOfFailedManualHintWaitsForUnsettledSpeech() async {
        let gate = AsyncGate()
        let delayGate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let (driver, _) = makeDriver(
            brain: brain,
            clock: ManualClock(),
            automaticAttemptDelay: { _ in await delayGate.enter() })
        driver.updateTranscriptionWork(true, for: .them)

        let outcome = Task {
            await turnOutcomeBeforeTimeout {
                await driver.handleTrigger(.manualHint)
            }
        }
        defer {
            outcome.cancel()
            driver.updateTranscriptionWork(false, for: .them)
        }
        await gate.waitUntilEntered()
        await gate.release()
        #expect(await waitUntilAsync { await delayGate.hasEntered })
        #expect(brain.calls.count == 1)

        await delayGate.release()
        // A broken manual-hint retry would make its second call while `.them` is still active.
        // Keep transcription unsettled long enough to prove the retry reached the settlement gate.
        #expect(!(await waitUntil {
            brain.calls.count == 2
        }))
        driver.updateTranscriptionWork(false, for: .them)
        #expect(await outcome.value == .spoke)
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
        let provenance = brain.requestContexts.compactMap { $0 }
        #expect(provenance.map(\.trigger) == ["turn_end", "pending_work"])
        #expect(provenance.map(\.sourceTrigger) == ["turn_end", "turn_end"])
        #expect(provenance.map(\.phase) == [.initial, .initial])
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

        // Compaction runs off the attempt path, and the summarizer's call count only proves the
        // request was dispatched — the summary is applied later, after that call returns. Drive
        // turns until the condensed block reaches a request rather than assuming a fixed one does.
        var condensed = ""
        for turn in 0..<20 where condensed.isEmpty {
            transcript.append(.init(speaker: .me, text: "next idea \(turn)", at: 5 + Double(turn)))
            await driver.handleTrigger(.turnEnd)
            let latest = (brain.calls.last ?? []).compactMap(\.text).joined(separator: "\n")
            if latest.contains("PROBLEM: tic-tac-toe columns.") { condensed = latest }
        }

        // The summarizer wrote it, not the coach brain. Later turns may compact again as history
        // regrows, so this is a floor rather than an exact count.
        #expect(summarizer.calls.count >= 1)
        #expect(condensed.contains("condensed"))
        #expect(condensed.contains("PROBLEM: tic-tac-toe columns."))
        #expect(!condensed.contains("the problem statement goes on"))   // raw early turn replaced
    }

    /// Compaction fails soft: if the summarizer errors, the full history simply rides along.
    @Test func compactionFailureKeepsFullHistory() async {
        let clock = ManualClock(now: 0)
        let recorder = BrainFailureRecorder()
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let summarizer = ScriptedThrowBrain(script: [nil])
        let (driver, transcript) = makeDriver(brain: brain, summarizer: summarizer, clock: clock,
                                              config: Config(historyCompactionTokenThreshold: 5),
                                              onBrainFailure: { recorder.record($0) })
        transcript.append(.init(speaker: .me, text: "a reasonably long problem statement to remember", at: 0))
        await driver.handleTrigger(.turnEnd)
        transcript.append(.init(speaker: .me, text: "next thought", at: 5))
        await driver.handleTrigger(.turnEnd)
        let second = brain.calls[1].compactMap(\.text).joined(separator: "\n")
        #expect(second.contains("a reasonably long problem statement to remember"))   // nothing lost
        #expect(recorder.failures.isEmpty)   // auxiliary failure never enters route health
        // Compaction runs off the attempt path, so confirm the failing path was actually exercised
        // rather than silently skipped — the history assertion above would hold either way.
        #expect(await waitUntilAsync { summarizer.calls.count >= 1 })
    }

    /// Compaction is auxiliary and must never hold the coaching slot. A summary still being written
    /// cannot delay the attempt that triggered it: otherwise every compaction spends its whole
    /// budget as dead air, and speech arriving meanwhile batches behind it instead of being coached.
    @Test func compactionDoesNotBlockTheAttempt() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let gate = AsyncGate()
        let summarizer = GatedSummarizer(gate: gate, summary: "PROBLEM: parked mid-summary.")
        let (driver, transcript) = makeDriver(brain: brain, summarizer: summarizer, clock: clock,
                                              config: Config(historyCompactionTokenThreshold: 5))
        transcript.append(.init(speaker: .me, text: "a reasonably long problem statement to remember", at: 0))
        await driver.handleTrigger(.turnEnd)
        transcript.append(.init(speaker: .me, text: "next thought", at: 5))

        let outcome = await turnOutcomeBeforeTimeout {
            await driver.handleTrigger(.turnEnd)
        }

        // The attempt completed…
        #expect(outcome == .silentByModel)
        // …while the summarizer was still parked, never having been released.
        #expect(await waitUntilAsync { await gate.hasEntered })
        await gate.release()
    }

    /// Compaction runs off the attempt path, so the turn box that Stop cancels does not own it.
    /// Session teardown must cancel and drain it itself, or a summary keeps a provider process alive
    /// and billing after the user stopped, and can still be writing when the audit seals.
    @Test func sessionTeardownCancelsAndDrainsCompaction() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let gate = AsyncGate()
        let summarizer = GatedSummarizer(gate: gate, summary: "never applied")
        let (driver, transcript) = makeDriver(brain: brain, summarizer: summarizer, clock: clock,
                                              config: Config(historyCompactionTokenThreshold: 5))
        transcript.append(.init(speaker: .me, text: "a reasonably long problem statement to remember", at: 0))
        await driver.handleTrigger(.turnEnd)
        transcript.append(.init(speaker: .me, text: "next thought", at: 5))
        await driver.handleTrigger(.turnEnd)
        #expect(await waitUntilAsync { await gate.hasEntered })

        // Teardown hands back the in-flight pass so the caller can drain it.
        let drained = driver.cancelBackgroundWork()
        #expect(drained != nil)
        await gate.release()
        await drained?.value

        // The cancelled summary never reached history: the next request still carries the raw turns.
        transcript.append(.init(speaker: .me, text: "third thought", at: 9))
        await driver.handleTrigger(.turnEnd)
        let third = brain.calls[2].compactMap(\.text).joined(separator: "\n")
        #expect(!third.contains("never applied"))
        #expect(third.contains("a reasonably long problem statement to remember"))
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
        let first = Task {
            await turnOutcomeBeforeTimeout {
                await driver.handleTrigger(.turnEnd)
            }
        }
        defer { first.cancel() }
        await brainGate.waitUntilEntered()
        await brainGate.release()
        #expect(await waitUntilAsync { await delayProbe.hasEntered })

        transcript.append(.init(speaker: .me, text: "wake with this new thought", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .busy)

        #expect(await first.value == .spoke)
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
        let freshAttemptUserText = brain.calls[1]
            .filter { $0.role == .user }
            .compactMap(\.text)
            .joined(separator: "\n")
        #expect(freshAttemptUserText.contains("new speech ended"))
        #expect(!freshAttemptUserText.contains("no speech for"))
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

    /// The settling speaker's delayed transcript-batch callback can arrive after a parked attempt has
    /// already admitted and included that speaker's final line. Its boundary identifies the callback
    /// as already consumed, so it cannot buy a duplicate request.
    @Test func deferredTurnForCommittedTranscriptDoesNotStartAnotherAttempt() async {
        let gate = AsyncGate()
        let brain = GatedBrain(
            gate: gate,
            response: .init(toolCalls: [.staySilent(callId: "quiet")]))
        let (driver, transcript) = makeDriver(
            brain: brain,
            clock: ManualClock(now: 0))
        let boundary = transcript.append(
            .init(speaker: .them, text: "settling speaker's final question", at: 1))

        async let first = driver.handleTrigger(.turnEnd)
        await gate.waitUntilEntered()
        #expect(await driver.handleTrigger(
            .turnEnd,
            transcriptBoundary: boundary) == .busy)
        await gate.release()

        #expect(await first == .silentByModel)
        #expect(brain.callCount == 1)
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

    func refreshClients(_ route: ConfiguredBrainRoute) {
        lock.withLock { driver }?.refreshBrainRouteClients(route)
    }
}

/// A brain that always throws, to exercise the `.brainError` outcome.
final class ThrowingBrain: BrainClient, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error
    private var calls = 0
    private var preparations = 0
    private var terminations = 0
    var callCount: Int { lock.withLock { calls } }
    var preparationCount: Int { lock.withLock { preparations } }
    var terminationCount: Int { lock.withLock { terminations } }

    init(error: Error = NSError(
        domain: "test", code: 401,
        userInfo: [NSLocalizedDescriptionKey: "test brain failed"])) {
        self.error = error
    }

    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        lock.withLock { calls += 1 }
        throw error
    }

    func prepare() {
        lock.withLock { preparations += 1 }
    }

    func terminate() {
        lock.withLock { terminations += 1 }
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
    private var _calls: [[ChatMessage]] = []
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    var calls: [[ChatMessage]] { lock.withLock { _calls } }
    private func record(_ messages: [ChatMessage]) -> Int {
        lock.lock(); defer { lock.unlock() }
        let index = _callCount
        _callCount += 1
        _calls.append(messages)
        return index
    }
    init(gate: AsyncGate, response: BrainResponse) { self.gate = gate; self.script = [response] }
    init(gate: AsyncGate, script: [BrainResponse]) { self.gate = gate; self.script = script }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        let index = record(messages)
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

/// Captures once, then parks and fails the continuation request. The next call belongs to a fresh
/// attempt and lets tests inspect exactly which provider-neutral context survives.
final class CaptureThenGatedFailureThenSpeakingBrain: BrainClient, @unchecked Sendable {
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
        switch index {
        case 0:
            return BrainResponse(
                toolCalls: [.captureScreen(callId: "capture")],
                rawToolCalls: [
                    RawToolCall(
                        id: "capture",
                        name: "capture_screen",
                        argumentsJSON: "{}"),
                ])
        case 1:
            await gate.enter()
            throw NSError(
                domain: "FutureProvider", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "temporary provider interruption"])
        default:
            return BrainResponse(
                toolCalls: [.speak(callId: "recovered", lines: ["used saved observation"])],
                rawToolCalls: [
                    RawToolCall(
                        id: "recovered",
                        name: "speak",
                        argumentsJSON: #"{"lines":["used saved observation"]}"#),
                ])
        }
    }
}

/// A summarizer that parks mid-summary, so a test can observe the triggering attempt completing
/// without it.
///
/// `@unchecked Sendable` is safe because `calls` is only ever touched under `lock`; the detached
/// compaction task and the polling test task would otherwise race on it.
private final class GatedSummarizer: BrainClient, @unchecked Sendable {
    private let gate: AsyncGate
    private let summary: String
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    init(gate: AsyncGate, summary: String) {
        self.gate = gate
        self.summary = summary
    }

    func respond(messages: [ChatMessage], tools: [ToolDef],
                 toolChoice: ToolChoice) async throws -> BrainResponse {
        lock.withLock { calls += 1 }
        // Release on cancellation so a regression fails the test instead of hanging it: `AsyncGate`
        // parks on a plain continuation, which a cancelled enclosing task group would wait on forever.
        await withTaskCancellationHandler {
            await gate.enter()
        } onCancel: {
            Task { await gate.release() }
        }
        return BrainResponse(toolCalls: [], outputText: summary)
    }
}

/// A one-shot async gate: the parked task signals it entered, then awaits release.
actor AsyncGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var hasEntered: Bool { entered }

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

    var hasEntered: Bool { entered }

    func waitForCancellation() async throws {
        entered = true
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 200_000_000,
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - startedAt < timeoutNanoseconds {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

private func waitUntilAsync(
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - startedAt < timeoutNanoseconds {
        if await condition() { return true }
        if Task.isCancelled { return false }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}

private func turnOutcomeBeforeTimeout(
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    operation: @escaping @Sendable () async -> TurnOutcome
) async -> TurnOutcome? {
    await withTaskGroup(of: TurnOutcome?.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            return nil
        }
        let outcome = await group.next() ?? nil
        group.cancelAll()
        return outcome
    }
}
