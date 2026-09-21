import Foundation
import Testing
@testable import JarvisCore

private func brainFailure(
    _ disposition: ProviderFailure.Disposition,
    _ message: String,
    provider: BrainProvider = .openAI
) -> ProviderFailure {
    ProviderFailure(
        source: .brain(provider), stage: .request, category: .unknown,
        disposition: disposition, identity: .init(), message: message)
}

private func unavailableFailure(_ target: BrainTarget, _ message: String) -> ProviderFailure {
    ProviderFailure(
        source: .brain(target.provider), stage: .process, category: .unavailable,
        disposition: .permanent, identity: .init(), message: message)
}

/// @unchecked: `lock` guards all mutable state, which the detached compaction task also reads.
final class ScriptedBrain: BrainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[ChatMessage]] = []
    private var _toolChoices: [ToolChoice] = []
    private var _offeredTools: [[ToolDef]] = []
    private var _requestContexts: [CoachingRequestContext?] = []
    private var _preparationCount = 0
    var calls: [[ChatMessage]] { lock.withLock { _calls } }
    var toolChoices: [ToolChoice] { lock.withLock { _toolChoices } }
    var offeredTools: [[ToolDef]] { lock.withLock { _offeredTools } }
    var requestContexts: [CoachingRequestContext?] { lock.withLock { _requestContexts } }
    var preparationCount: Int { lock.withLock { _preparationCount } }
    let script: [BrainResponse]
    init(script: [BrainResponse]) { self.script = script }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        let index = lock.withLock { () -> Int in
            _calls.append(messages)
            _toolChoices.append(toolChoice)
            _offeredTools.append(tools)
            _requestContexts.append(CoachingRequestAttribution.current)
            return _calls.count - 1
        }
        return script[min(index, script.count - 1)]
    }
    func prepare() { lock.withLock { _preparationCount += 1 } }
}

/// Each nil script entry throws. @unchecked: all mutable state is guarded by `lock`.
final class ScriptedThrowBrain: BrainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[ChatMessage]] = []
    private var _requestContexts: [CoachingRequestContext?] = []
    private var idx = 0
    var calls: [[ChatMessage]] { lock.withLock { _calls } }
    var requestContexts: [CoachingRequestContext?] { lock.withLock { _requestContexts } }
    let script: [BrainResponse?]
    let error: any Error
    init(script: [BrainResponse?], error: any Error = NSError(domain: "test", code: 500)) {
        self.script = script
        self.error = error
    }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        let r = lock.withLock { () -> BrainResponse? in
            _calls.append(messages)
            _requestContexts.append(CoachingRequestAttribution.current)
            let reply = script[min(idx, script.count - 1)]; idx += 1
            return reply
        }
        guard let r else { throw error }
        return r
    }
}

/// @unchecked: `lock` guards the count, which the detached capture task writes.
final class FakeScreen: ScreenCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCaptureCount = 0
    var captureCount: Int { lock.withLock { storedCaptureCount } }
    let payload: String
    let recognizedText: String?
    init(payload: String = "ZmFrZS1qcGVn", recognizedText: String? = nil) { // "fake-jpeg"
        self.payload = payload; self.recognizedText = recognizedText
    }
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
        lock.withLock { storedCaptureCount += 1 }
        return ScreenSnapshot(
            imageBase64: payload,
            textEvidence: recognizedText.map {
                ScreenTextEvidence(text: $0, source: .onDeviceOCR, coverage: .currentViewport)
            }.map { [$0] } ?? [])
    }
    func cancelCapture() {}
}

/// @unchecked: no stored state.
final class UnavailableScreen: ScreenCapturing, @unchecked Sendable {
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? { nil }
    func cancelCapture() {}
}

/// @unchecked: counts are guarded by `lock`, and the semaphores are thread-safe.
final class GatedScreen: ScreenCapturing, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedCaptureCount = 0
    private var storedCancelCount = 0
    var captureCount: Int { lock.withLock { storedCaptureCount } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }
    let payload: String
    init(payload: String = "ZmFrZS1qcGVn") { self.payload = payload }
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
        lock.withLock { storedCaptureCount += 1 }
        entered.signal()
        release.wait()
        return ScreenSnapshot(imageBase64: payload)
    }
    func cancelCapture() {
        lock.withLock { storedCancelCount += 1 }
        release.signal()
    }
}

/// @unchecked: counts are guarded by `lock`, and the semaphores are thread-safe.
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

    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
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

/// @unchecked: `lock` guards the log, which the main actor writes while tests read it.
final class FakeOverlay: OverlayRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRendered: [[String]] = []
    var rendered: [[String]] { lock.withLock { storedRendered } }
    func render(_ lines: [String]) {
        lock.withLock { storedRendered.append(lines) }
    }
}

// Serialized: a parked GatedScreen or HeldCleanupScreen capture holds a cooperative-pool thread,
// and a CI runner has only three, so overlapping parks can starve every release path.
@Suite(.serialized) struct CoachDriverPipelineTests {
    private func makeDriver(activity: (any ActivityEventRecording)? = nil,
                            brain: BrainClient, brainProvider: BrainProvider? = nil,
                            summarizer: BrainClient? = nil,
                            screen: ScreenCapturing = FakeScreen(),
                            overlay: OverlayRendering = FakeOverlay(),
                            clock: Clock, config: Config = .default,
                            capabilities: CoachCapabilities = .default,
                            coachingAttempts: (any CoachingAttemptAuditing)? = nil,
                            automaticAttemptDelay: @escaping CoachDriver.AutomaticAttemptDelay = { _ in },
                            onRouteFailure: (@MainActor @Sendable (ProviderFailure) -> Void)? = nil,
                            prepMaterial: (any PrepMaterialSearching)? = nil)
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
            onExhausted: { _, failure in onRouteFailure?(failure) },
            onTerminated: { _, failure in onRouteFailure?(failure) })
        let driver = CoachDriver(
            config: config, transcript: transcript,
            route: route, screen: screen, overlay: overlay, clock: clock,
            coachingAttempts: coachingAttempts,
            plan: SessionPlan(revision: 0, screen: SessionPlan.default.screen),
            automaticAttemptDelay: automaticAttemptDelay,
            activity: activity,
            capabilities: capabilities,
            prepMaterial: prepMaterial
        )
        return (driver, transcript)
    }

    private func makeRouteDriver(
        _ targets: [(BrainTarget, BrainClient)],
        screen: ScreenCapturing = FakeScreen(),
        overlay: OverlayRendering = FakeOverlay(),
        onAdvanced: (@Sendable (BrainTarget, BrainTarget, ProviderFailure) -> Void)? = nil,
        onSkipped: (@Sendable (BrainTarget, ProviderFailure) -> Void)? = nil,
        onExhausted: (@MainActor @Sendable (BrainTarget, ProviderFailure) -> Void)? = nil,
        activity: (any ActivityEventRecording)? = nil
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
                activity: activity),
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
        // Poll committed state, not yields: CI can finish yielding before the provider resumes.
        await waitUntilAsync { driver.takeBrainSelectionStep().alreadyExhausted }
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
        #expect(brain.calls[1].contains { $0.role == .assistant && $0.toolCalls?.first?.name == "capture_screen" })
        #expect(brain.calls[1].contains { $0.role == .tool && $0.toolCallId == "c1" })
        #expect(brain.calls[1].contains { $0.imageBase64JPEG != nil })
        #expect(brain.calls[1].first { $0.role == .tool }?.text == "screenshot captured")
        #expect(brain.requestContexts.compactMap { $0 }.map(\.phase) == [
            .initial, .captureScreenContinuation,
        ])
        #expect(Set(brain.requestContexts.compactMap { $0 }.map(\.attemptID)).count == 1)
    }

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
        #expect(toolResult.contains("while(true){ cnt--; }"))
        #expect(toolResult.contains("may misread tokens"))
        #expect(brain.calls[1].contains { $0.imageBase64JPEG != nil })
    }

    @Test func screenshotLandsInActivityLogAsValidJpeg() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-e2e-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (activityLog, evidence) = ActivityLog.recordingSession(in: dir)
        defer { activityLog.disable(); try? FileManager.default.removeItem(at: dir) }

        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c1")],
                  rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.speak(callId: "s1", lines: ["Watch the off-by-one there."])],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                             argumentsJSON: #"{"lines":["Watch the off-by-one there."]}"#)]),
        ])
        let screen = FakeScreen(payload: TestFixtures.tinyJpegBase64)
        let (driver, transcript) = makeDriver(
            activity: evidence, brain: brain, screen: screen, clock: clock)
        transcript.append(.init(speaker: .me, text: "here's my solution", at: 100))

        await driver.handleTrigger(.turnEnd)

        _ = await evidence.close()   // barrier: drains this session's accepted rows
        let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        #expect(jsonl.contains("looking at your screen"))
        #expect(jsonl.contains("shot-"))

        let shots = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("shot-") && $0.pathExtension == "jpg" }
        let shot = try #require(try shots.first { try Data(contentsOf: $0) == TestFixtures.tinyJpeg },
                                "expected our screenshot (byte-exact) in the activity log dir")
        let bytes = try Data(contentsOf: shot)
        #expect(bytes.prefix(2) == Data([0xFF, 0xD8]) && bytes.suffix(2) == Data([0xFF, 0xD9]))
        let perms = try FileManager.default.attributesOfItem(atPath: shot.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    @Test func manualHintTriggerAndPrefilledMessageLandInActivityLog() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-hintlog-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (activityLog, evidence) = ActivityLog.recordingSession(in: dir)
        defer { activityLog.disable(); try? FileManager.default.removeItem(at: dir) }

        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["use a hash map"])])])
        let (driver, transcript) = makeDriver(
            activity: evidence, brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "stuck on two-sum", at: 100))

        await driver.handleTrigger(.manualHint)

        _ = await evidence.close()   // barrier: drains this session's accepted rows
        let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        #expect(jsonl.contains("hint shortcut"))
    }

    @Test func activityLogExcludesCoachingDiagnostics() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-activity-boundary-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (activityLog, evidence) = ActivityLog.recordingSession(in: dir)
        defer { activityLog.disable(); try? FileManager.default.removeItem(at: dir) }
        try await JarvisLogAttachmentLock.withExclusiveAttachment {
            JarvisLog.attach(to: evidence)
            defer { JarvisLog.detach() }

            let brain = ScriptedBrain(script: [
                .init(toolCalls: [.speak(callId: "s", lines: ["activity-boundary-tip-417"])])
            ])
            let (driver, _) = makeDriver(
                activity: evidence, brain: brain, clock: ManualClock(now: 417))

            #expect(await driver.handleTrigger(.silence(secondsQuiet: 417)) == .spoke)

            _ = await evidence.close()   // barrier: drains this session's accepted rows
            let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
            #expect(jsonl.contains("activity-boundary-tip-417"))
            #expect(!jsonl.contains("quiet for 417s"))
            #expect(!jsonl.contains("thinking"))

            let debug = try String(contentsOf: dir.appendingPathComponent("jarvis-debug.log"), encoding: .utf8)
            #expect(debug.contains("quiet for 417s"))
            #expect(debug.contains("thinking"))
            #expect(debug.contains("activity-boundary-tip-417"))
        }
    }

    @Test func successfulRetryDoesNotReportFailedCycle() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "jarvis-attempt-failure-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (activityLog, evidence) = ActivityLog.recordingSession(in: dir)
        defer { activityLog.disable(); try? FileManager.default.removeItem(at: dir) }

        let brain = ScriptedThrowBrain(
            script: [
                nil,
                nil,
                .init(toolCalls: [.speak(callId: "recovered", lines: ["recovered coaching"])]),
            ],
            error: NSError(domain: "test", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "app-server refused: Authorization: Bearer abc123token",
            ]))
        let (driver, transcript) = makeDriver(
            activity: evidence, brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "keep listening after failures", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        _ = await evidence.close()
        let snapshot = activityLog.attach { _ in }
        #expect(snapshot.rows.contains { $0.contains("recovered coaching") })
        #expect(!snapshot.rows.contains { $0.contains("request failed") })
    }

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
            DispatchQueue.global().async { screen.entered.wait(); cont.resume() }
        }
        task.cancel()
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
        #expect(screen.captureCount == 1)
        #expect(screen.cancelCount == 1)
        #expect(overlay.rendered.isEmpty)
        #expect(await brain.recordedCallCount() == 1)
    }

    @Test func emptySpeakLinesStillReportsSpoke() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: [])])])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(overlay.rendered == [[]])
    }

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
        #expect(second.contains { ($0.text ?? "").contains("thinking about the columns") })
        #expect(!second.contains { $0.role == .assistant && $0.toolCalls != nil })
        #expect(!second.contains { $0.role == .tool })
    }

    @Test func staySilentActionLandsInActivityLog() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-silent-action-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (activityLog, evidence) = ActivityLog.recordingSession(in: dir)
        defer { activityLog.disable(); try? FileManager.default.removeItem(at: dir) }

        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")],
                  rawToolCalls: [RawToolCall(id: "quiet", name: "stay_silent", argumentsJSON: "{}")])
        ])
        let (driver, transcript) = makeDriver(
            activity: evidence, brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "thinking about the columns", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)

        _ = await evidence.close()
        let snapshot = activityLog.attach { _ in }
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows[0].contains("stayed silent"))
    }

    @Test func failedScreenActionAndStaySilentBothLandInActivityLog() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-failed-screen-action-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (activityLog, evidence) = ActivityLog.recordingSession(in: dir)
        defer { activityLog.disable(); try? FileManager.default.removeItem(at: dir) }

        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "capture")],
                  rawToolCalls: [RawToolCall(id: "capture", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.staySilent(callId: "quiet")],
                  rawToolCalls: [RawToolCall(id: "quiet", name: "stay_silent", argumentsJSON: "{}")]),
        ])
        let (driver, transcript) = makeDriver(
            activity: evidence, brain: brain, screen: UnavailableScreen(),
            clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "look at this", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)

        _ = await evidence.close()
        let snapshot = activityLog.attach { _ in }
        #expect(snapshot.rows.count == 2)
        #expect(snapshot.rows[0].contains("couldn't view your screen"))
        #expect(snapshot.rows[0].contains("screen capture failed"))
        #expect(snapshot.rows[0].contains("Screen Recording permission"))
        #expect(snapshot.rows[1].contains("stayed silent"))
    }

    @Test func silentSilenceCheckLeavesNoTriggerNoteInHistory() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "q1")],
                                                 rawToolCalls: [RawToolCall(id: "q1", name: "stay_silent", argumentsJSON: "{}")])])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 120)) == .silentByModel)

        transcript.append(.init(speaker: .me, text: "ok here is an idea", at: 5))
        await driver.handleTrigger(.turnEnd)
        // Only user messages: the system prompt legitimately contains a "no speech for" example.
        #expect(!brain.calls[1].contains { $0.role == .user && ($0.text ?? "").contains("no speech for") })
    }

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
        #expect(last.contains { $0.role == .user && ($0.text ?? "").contains("no speech for") })
        #expect(last.contains { $0.role == .tool && $0.toolCallId == "c1" })
    }

    @Test func noToolCallsEndCycleAfterThreeAttemptsWithoutRendering() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: Array(repeating: .init(toolCalls: []), count: 4)
            + [.init(toolCalls: [.staySilent(callId: "complete")])])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(brain.calls.count == 3)
        #expect(overlay.rendered.isEmpty)
    }

    // MARK: - The substance gate: clear hesitation sounds never buy a brain request

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

    @Test func compositeFillerTurnEndSkipsTheBrain() async {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(now: 0))
        transcript.append(.init(speaker: .me, text: "Uh. Hmm. Oh, oh.", at: 1))

        #expect(await driver.handleTrigger(.turnEnd) == .skippedFillerOnly)
        #expect(brain.calls.isEmpty)
    }

    @Test func interviewerQuestionReachesTheBrain() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["Walk through your loop out loud."])])])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .them, text: "那你是怎么做的?", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(brain.calls.count == 1)
    }

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

    @Test func emptyDeltaTurnEndSkipsTheBrain() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, _) = makeDriver(brain: brain, clock: clock)
        #expect(await driver.handleTrigger(.turnEnd) == .skippedFillerOnly)
        #expect(brain.calls.isEmpty)
    }

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

    @Test func silenceTriggerStillReachesTheBrainWithoutNewSpeech() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, _) = makeDriver(brain: brain, clock: clock)
        await driver.handleTrigger(.silence(secondsQuiet: 120))
        #expect(brain.calls.count == 1)
    }

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
        let fallbackTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
        let primary = ThrowingBrain()
        let fallback = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "fallback", lines: ["fallback tip"])]),
        ])
        let transitions = RouteTransitionRecorder()
        let (driver, transcript) = makeRouteDriver(
            [(primaryTarget, primary), (fallbackTarget, fallback)],
            onAdvanced: { previous, current, _ in transitions.record(from: previous, to: current) })
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
        let fallbackTarget = BrainTarget(provider: .codexSubscription, modelID: "gpt-5.6-sol")
        let primary = ThrowingBrain(error: brainFailure(.permanent, "invalid credentials"))
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
            (BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5"), fallback),
        ])
        transcript.append(.init(speaker: .me, text: "first question", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        transcript.append(.init(speaker: .me, text: "second question", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        #expect(primary.callCount == 3)
        #expect(fallback.calls.count == 2)
    }

    @Test func refreshingRouteClientsPreservesFallbackCursor() async {
        let primaryTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
        let fallbackTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let primary = ThrowingBrain(error: brainFailure(.permanent, "primary permanently failed"))
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
        #expect(refreshedFallback.calls.count == 1)
    }

    @Test func reconfiguringRouteClientsPreservesFallbackCursor() async {
        let primaryTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
        let fallbackTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let primary = ThrowingBrain(error: brainFailure(.permanent, "primary permanently failed"))
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
        #expect(reconfiguredFallback.calls.count == 1)
        #expect(reconfiguredFallback.preparationCount == 1)
    }

    @Test func scopedCredentialRefreshKeepsOtherProviderClients() async {
        let primaryTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let fallbackTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
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

        let refreshedPrimary = ThrowingBrain(error: brainFailure(.permanent, "new credential rejected"))
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
        let primaryTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
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

    /// Drives commit and delivery directly: under `handleTrigger` they are adjacent, leaving no
    /// observable window for the refresh to land in.
    @Test func aCommittedSkipIsDeliveredToTheCallbackItWasCommittedAgainst() async throws {
        let unavailableTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
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
                        failure: unavailableFailure(unavailableTarget, "the sign-in service isn't running")),
                    ConfiguredBrainTarget(
                        target: availableTarget,
                        brain: ScriptedBrain(script: [
                            .init(toolCalls: [.staySilent(callId: "old-client")]),
                        ])),
                ],
                onSkipped: { target, _ in originalSkip.record(target) }),
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })

        let committed = try #require(driver.takeBrainSelectionStep().skipped)
        #expect(driver.refreshBrainRouteClients(ConfiguredBrainRoute(
            targets: [
                ConfiguredBrainTarget(
                    unavailable: unavailableTarget,
                    failure: unavailableFailure(unavailableTarget, "the sign-in service still isn't running")),
                ConfiguredBrainTarget(
                    target: availableTarget,
                    brain: ScriptedBrain(script: [
                        .init(toolCalls: [.staySilent(callId: "new-client")]),
                    ])),
            ],
            onSkipped: { target, _ in refreshedSkip.record(target) })))
        await driver.deliverRouteSkip(committed)

        #expect(originalSkip.targets == [unavailableTarget])
        #expect(refreshedSkip.targets.isEmpty)
    }

    @Test func aCommittedAdvanceIsDeliveredToTheCallbackItWasCommittedAgainst() async throws {
        let unavailableTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
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
                        failure: unavailableFailure(unavailableTarget, "the sign-in service isn't running")),
                    ConfiguredBrainTarget(
                        target: availableTarget,
                        brain: ScriptedBrain(script: [
                            .init(toolCalls: [.staySilent(callId: "old-client")]),
                        ])),
                ],
                onAdvanced: { previous, current, _ in originalAdvance.record(from: previous, to: current) }),
            screen: FakeScreen(),
            overlay: FakeOverlay(),
            clock: ManualClock(),
            automaticAttemptDelay: { _ in })

        // The first step skips the unavailable head; only the second commits the advance.
        _ = driver.takeBrainSelectionStep()
        let committed = try #require(driver.takeBrainSelectionStep().advanced)
        #expect(driver.refreshBrainRouteClients(ConfiguredBrainRoute(
            targets: [
                ConfiguredBrainTarget(
                    unavailable: unavailableTarget,
                    failure: unavailableFailure(unavailableTarget, "the sign-in service still isn't running")),
                ConfiguredBrainTarget(
                    target: availableTarget,
                    brain: ScriptedBrain(script: [
                        .init(toolCalls: [.staySilent(callId: "new-client")]),
                    ])),
            ],
            onAdvanced: { previous, current, _ in refreshedAdvance.record(from: previous, to: current) })))
        await driver.deliverRouteAdvance(committed)

        #expect(originalAdvance.events == [
            .init(from: unavailableTarget, to: availableTarget),
        ])
        #expect(refreshedAdvance.events.isEmpty)
    }

    @Test func refreshingClientsDuringASkipRetargetsOnlyTheFollowingAttempt() async {
        let unavailableTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
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
                        failure: unavailableFailure(unavailableTarget, "the sign-in service isn't running")),
                    ConfiguredBrainTarget(target: availableTarget, brain: originalAvailable),
                ],
                onSkipped: { target, _ in
                    originalSkip.record(target)
                    holder.refreshClients(ConfiguredBrainRoute(
                        targets: [
                            ConfiguredBrainTarget(
                                unavailable: unavailableTarget,
                                failure: unavailableFailure(unavailableTarget, "the sign-in service still isn't running")),
                            ConfiguredBrainTarget(
                                target: availableTarget,
                                brain: refreshedAvailable),
                        ],
                        onSkipped: { target, _ in refreshedSkip.record(target) }))
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

    @Test func refreshingClientsDuringAnAdvanceRetargetsOnlyTheFollowingAttempt() async {
        let unavailableTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
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
                        failure: unavailableFailure(unavailableTarget, "the sign-in service isn't running")),
                    ConfiguredBrainTarget(target: availableTarget, brain: originalAvailable),
                ],
                onAdvanced: { previous, current, _ in
                    originalAdvance.record(from: previous, to: current)
                    holder.refreshClients(ConfiguredBrainRoute(
                        targets: [
                            ConfiguredBrainTarget(
                                unavailable: unavailableTarget,
                                failure: unavailableFailure(unavailableTarget, "the sign-in service still isn't running")),
                            ConfiguredBrainTarget(
                                target: availableTarget,
                                brain: refreshedAvailable),
                        ],
                        onAdvanced: { previous, current, _ in refreshedAdvance.record(from: previous, to: current) }))
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
        let fallbackTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
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
        let fallbackTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
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
        let fallbackTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
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
            error: brainFailure(.permanent, "terminal route failure"))
        let originalDelivery = RouteExhaustionRecorder()
        let refreshedDelivery = RouteExhaustionRecorder()
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default,
            transcript: transcript,
            route: ConfiguredBrainRoute(
                targets: [ConfiguredBrainTarget(target: target, brain: failed)],
                onTerminated: { originalDelivery.record(target: $0, failure: $1) }),
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

        let refreshed = ThrowingBrain(error: brainFailure(.permanent, "refreshed client should never run"))
        #expect(driver.refreshBrainRouteClients(ConfiguredBrainRoute(
            targets: [ConfiguredBrainTarget(target: target, brain: refreshed)],
            onTerminated: { refreshedDelivery.record(target: $0, failure: $1) })))

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
        let replacementTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
        let responseGate = AsyncGate()
        let failed = GatedThrowingBrain(
            gate: responseGate,
            error: brainFailure(.permanent, "old route failed"))
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

    @Test func permanentFallbackFailureEndsCycleWhileTemporaryPrimaryRemainsEligible() async {
        let first = ThrowingBrain()
        let second = ThrowingBrain(error: brainFailure(.permanent, "signed out"))
        let exhausted = RouteExhaustionRecorder()
        let (driver, transcript) = makeRouteDriver(
            [
                (BrainTarget(provider: .openAI, modelID: "gpt-5.5"), first),
                (BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5"), second),
            ],
            onExhausted: { exhausted.record(target: $0, failure: $1) })
        transcript.append(.init(speaker: .me, text: "bounded failure", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(first.callCount == 3)
        #expect(second.callCount == 1)
        #expect(exhausted.targets.map(\.provider) == [.claudeSubscription])
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(exhausted.targets.count == 1)
    }

    @Test func advancingPastAPermanentPrimarySpeaksOnTheFallback() async {
        let primaryTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
        let fallbackTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let permanent = brainFailure(.permanent, "provider boundary is permanently unavailable")
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
        #expect(fallback.calls.count == 1)
    }

    @Test func settingsRevisionDuringFinalFailureKeepsPendingWorkAlive() async {
        let failedTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let replacementTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
        let failed = ThrowingBrain(error: brainFailure(.temporary, "old route failed"))
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
        #expect(failed.callCount == 3)
        #expect(replacement.calls.count == 1)
        #expect(replacement.calls[0].contains {
            ($0.text ?? "").contains("do not orphan this transcript")
        })
    }

    @Test func settingsRevisionDuringUnavailableFinalTargetReselectsImmediately() async {
        let unavailableTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
        let replacementTarget = BrainTarget(provider: .codexSubscription, modelID: "gpt-5.6-sol")
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
                    failure: unavailableFailure(unavailableTarget, "the sign-in service isn't running")),
            ],
            onSkipped: { _, _ in holder.updateRoute(replacementRoute) })
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
        let unavailableTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
        let finalTarget = BrainTarget(provider: .codexSubscription, modelID: "gpt-5.6-sol")
        let primary = ThrowingBrain(error: brainFailure(.permanent, "primary permanently failed"))
        let final = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "final", lines: ["final target"])]),
        ])
        let skipped = RouteTargetRecorder()
        let route = ConfiguredBrainRoute(
            targets: [
                ConfiguredBrainTarget(target: primaryTarget, brain: primary),
                ConfiguredBrainTarget(
                    unavailable: unavailableTarget,
                    failure: unavailableFailure(unavailableTarget, "the sign-in service isn't running")),
                ConfiguredBrainTarget(target: finalTarget, brain: final),
            ],
            onSkipped: { target, _ in skipped.record(target) })
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
                (BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5"), fallback),
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

    @Test func automaticQuestionRunsWhileBothSpeakersHaveOnlyLaterPendingSpeech() async throws {
        let brain = ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "quiet")])])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock())
        driver.updateTranscriptionWork(.pending(since: 3), for: .me)
        driver.updateTranscriptionWork(.pending(since: 4), for: .them)
        let boundary = transcript.append(.init(speaker: .me, text: "What is the complexity?", at: 2))
        let outcome = await turnOutcomeBeforeTimeout {
            await driver.handleTrigger(.turnEnd, transcriptBoundary: boundary)
        }
        #expect(outcome == .silentByModel)
        #expect(brain.calls.count == 1)
        #expect(brain.calls.first?.contains { ($0.text ?? "").contains("What is the complexity?") } == true)
    }

    @Test func earlierPendingSpeechStillBlocksAndIsIncludedWhenLaterSpeechRemains() async throws {
        let brain = ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "quiet")])])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock())
        driver.updateTranscriptionWork(.pending(since: 1), for: .them)
        transcript.append(.init(speaker: .me, text: "Yes, that approach.", at: 2))
        let task = Task { await turnOutcomeBeforeTimeout { await driver.handleTrigger(.turnEnd) } }
        defer { task.cancel(); driver.updateTranscriptionWork(.settled, for: .them) }
        #expect(!(await waitUntil { !brain.calls.isEmpty }))
        transcript.append(.init(speaker: .them, text: "Which approach?", at: 1))
        driver.updateTranscriptionWork(.pending(since: 3), for: .them)
        #expect(await task.value == .silentByModel)
        let request = try #require(brain.calls.first)
        let text = request.compactMap(\.text).joined(separator: "\n")
        let earlier = try #require(text.range(of: "Which approach?"))
        let later = try #require(text.range(of: "Yes, that approach."))
        #expect(earlier.lowerBound < later.lowerBound)
    }

    @Test func silenceWaitsForBothSpeakersButNewCompletedTurnCanWakeIt() async throws {
        let brain = ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "quiet")])])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock())
        driver.updateTranscriptionWork(.pending(since: 3), for: .them)
        transcript.append(.init(speaker: .me, text: "What is the complexity?", at: 2))
        let task = Task {
            await turnOutcomeBeforeTimeout { await driver.handleTrigger(.silence(secondsQuiet: 10)) }
        }
        defer { task.cancel(); driver.updateTranscriptionWork(.settled, for: .them) }
        #expect(!(await waitUntil { !brain.calls.isEmpty }))
        #expect(await driver.handleTrigger(.turnEnd, transcriptBoundary: 1) == .busy)
        #expect(await task.value == .silentByModel)
        #expect(brain.calls.count == 1)
    }

    @Test func waitingAttemptRechecksNewerFinalsBeforeAdmission() async throws {
        let brain = ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "quiet")])])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock())
        driver.updateTranscriptionWork(.pending(since: 1), for: .them)
        transcript.append(.init(speaker: .me, text: "First question.", at: 2))
        let task = Task { await turnOutcomeBeforeTimeout { await driver.handleTrigger(.turnEnd) } }
        defer { task.cancel(); driver.updateTranscriptionWork(.settled, for: .them) }
        #expect(!(await waitUntil { !brain.calls.isEmpty }))
        transcript.append(.init(speaker: .me, text: "Later reply.", at: 4))
        driver.updateTranscriptionWork(.pending(since: 3), for: .them)
        #expect(!(await waitUntil { !brain.calls.isEmpty }))
        transcript.append(.init(speaker: .them, text: "Middle question.", at: 3))
        driver.updateTranscriptionWork(.pending(since: 5), for: .them)
        #expect(await task.value == .silentByModel)
        let request = try #require(brain.calls.first)
        let text = request.compactMap(\.text).joined(separator: "\n")
        let middle = try #require(text.range(of: "Middle question."))
        let later = try #require(text.range(of: "Later reply."))
        #expect(middle.lowerBound < later.lowerBound)
    }

    @Test func initialAutomaticAttemptWaitsForSettlementAndOrdersLateEarlierSpeech() async throws {
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock())
        driver.updateTranscriptionWork(.pending(since: nil), for: .them)
        transcript.append(.init(speaker: .me, text: "Yep.", at: 20))

        let outcome = Task {
            await turnOutcomeBeforeTimeout {
                await driver.handleTrigger(.turnEnd)
            }
        }
        defer {
            outcome.cancel()
            driver.updateTranscriptionWork(.settled, for: .them)
        }

        #expect(!(await waitUntil { !brain.calls.isEmpty }))
        transcript.append(.init(speaker: .them, text: "Did you see the pop-up?", at: 10))
        driver.updateTranscriptionWork(.settled, for: .them)

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
            driver.updateTranscriptionWork(.settled, for: .them)
        }
        await gate.waitUntilEntered()

        driver.updateTranscriptionWork(.pending(since: nil), for: .them)
        transcript.append(.init(speaker: .me, text: "Yep.", at: 20))
        #expect(await driver.handleTrigger(.turnEnd) == .busy)
        await gate.release()

        #expect(!(await waitUntil { brain.callCount == 2 }))
        transcript.append(.init(speaker: .them, text: "Did you see the pop-up?", at: 10))
        driver.updateTranscriptionWork(.settled, for: .them)

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
        driver.updateTranscriptionWork(.pending(since: nil), for: .me)
        driver.updateTranscriptionWork(.pending(since: nil), for: .them)
        await gate.release()
        #expect(await waitUntilAsync { await delayGate.hasEntered })
        #expect(brain.calls.count == 1)

        driver.updateTranscriptionWork(.settled, for: .me)
        #expect(brain.calls.count == 1)

        await delayGate.release()
        // A bounded wait gives a broken retry the chance to make the forbidden second call.
        #expect(!(await waitUntil {
            brain.calls.count == 2
        }))
        driver.updateTranscriptionWork(.settled, for: .them)
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
            driver.updateTranscriptionWork(.settled, for: .them)
        }
        await gate.waitUntilEntered()
        driver.updateTranscriptionWork(.pending(since: nil), for: .them)
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

    @Test(arguments: [TriggerReason.manualHint, .manualExplanation, .manualCode])
    func manualHintWakesFailedAttemptEvenWhileSpeechIsUnsettled(_ reason: TriggerReason) async {
        let gate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let (driver, transcript) = makeDriver(
            brain: brain,
            clock: ManualClock(),
            capabilities: CoachCapabilities.compose(
                disabledTools: [], prepSourcesConfigured: false))
        transcript.append(.init(speaker: .me, text: "first attempt", at: 0))

        async let outcome = driver.handleTrigger(.turnEnd)
        await gate.waitUntilEntered()
        driver.updateTranscriptionWork(.pending(since: nil), for: .them)
        #expect(await driver.handleTrigger(reason) == .busy)
        await gate.release()

        #expect(await outcome == .spoke)
        #expect(brain.calls.count == 2)
        #expect(brain.calls.last?.first?.text?.contains("# Detail") == true)
        driver.updateTranscriptionWork(.settled, for: .them)
    }

    @Test(arguments: [TriggerReason.manualHint, .manualExplanation, .manualCode])
    func automaticRetryOfFailedManualHintWaitsForUnsettledSpeech(_ reason: TriggerReason) async {
        let gate = AsyncGate()
        let delayGate = AsyncGate()
        let brain = GatedFailureThenSpeakingBrain(gate: gate)
        let (driver, _) = makeDriver(
            brain: brain,
            clock: ManualClock(),
            capabilities: CoachCapabilities.compose(
                disabledTools: [], prepSourcesConfigured: false),
            automaticAttemptDelay: { _ in await delayGate.enter() })
        driver.updateTranscriptionWork(.pending(since: nil), for: .them)

        let outcome = Task {
            await turnOutcomeBeforeTimeout {
                await driver.handleTrigger(reason)
            }
        }
        defer {
            outcome.cancel()
            driver.updateTranscriptionWork(.settled, for: .them)
        }
        await gate.waitUntilEntered()
        await gate.release()
        #expect(await waitUntilAsync { await delayGate.hasEntered })
        #expect(brain.calls.count == 1)

        await delayGate.release()
        // A bounded wait gives a broken retry the chance to call while `.them` is still active.
        #expect(!(await waitUntil {
            brain.calls.count == 2
        }))
        driver.updateTranscriptionWork(.settled, for: .them)
        #expect(await outcome.value == .spoke)
        #expect(brain.calls.count == 2)
        #expect(brain.calls.last?.first?.text?.contains("# Detail") == true)
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
        #expect(occurrences == 1)
    }

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
        #expect(brain.calls.last!.contains { ($0.text ?? "").contains("important words") })
        let provenance = brain.requestContexts.compactMap { $0 }
        #expect(provenance.map(\.trigger) == ["turn_end", "pending_work"])
        #expect(provenance.map(\.sourceTrigger) == ["turn_end", "turn_end"])
        #expect(provenance.map(\.phase) == [.initial, .initial])
    }

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

        let second = brain.calls[1]
        let rawIndex = second.firstIndex { $0.rawItemsJSON != nil }
        let resultIndex = second.firstIndex { $0.role == .tool && $0.toolCallId == "c1" }
        #expect(rawIndex != nil && resultIndex != nil)
        if let r = rawIndex, let t = resultIndex { #expect(r < t) }
        #expect(second.first { $0.rawItemsJSON != nil }?.rawItemsJSON == outputItems)
        #expect(second.first { $0.rawItemsJSON != nil }?.toolCalls
            == [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")])
        #expect(second.filter { $0.toolCalls?.contains { $0.name == "capture_screen" } ?? false }.count == 1)

        let third = brain.calls[2]
        #expect(!third.contains { $0.rawItemsJSON != nil })
        #expect(third.contains { $0.toolCalls == [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")] })
    }

    @Test func screenshotsStubbedAfterTheirTurnCommits() async {
        let clock = ManualClock(now: 0)
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
        #expect(!last.contains { $0.imageBase64JPEG != nil })
        #expect(last.filter { ($0.text ?? "").contains("no longer available") }.count == 2)
    }

    // MARK: - Compaction

    @Test func historyCompactsIntoSummaryPastThreshold() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let summarizer = ScriptedBrain(script: [.init(toolCalls: [], outputText: "PROBLEM: tic-tac-toe columns.")])
        let (driver, transcript) = makeDriver(brain: brain, summarizer: summarizer, clock: clock,
                                              config: Config(historyCompactionTokenThreshold: 30))
        transcript.append(.init(speaker: .me, text: String(repeating: "the problem statement goes on ", count: 8), at: 0))
        await driver.handleTrigger(.turnEnd)
        transcript.append(.init(speaker: .me, text: "and some more detail about the grid", at: 1))
        await driver.handleTrigger(.turnEnd)

        // The summary lands asynchronously after the summarizer returns, so poll with turns.
        var condensed = ""
        for turn in 0..<20 where condensed.isEmpty {
            transcript.append(.init(speaker: .me, text: "next idea \(turn)", at: 5 + Double(turn)))
            await driver.handleTrigger(.turnEnd)
            let latest = (brain.calls.last ?? []).compactMap(\.text).joined(separator: "\n")
            if latest.contains("PROBLEM: tic-tac-toe columns.") { condensed = latest }
        }

        // A floor: later turns may compact again as history regrows.
        #expect(summarizer.calls.count >= 1)
        #expect(condensed.contains("condensed"))
        #expect(condensed.contains("PROBLEM: tic-tac-toe columns."))
        #expect(!condensed.contains("the problem statement goes on"))
        await driver.cancelBackgroundWork()?.value
    }

    @Test func compactionFailureKeepsFullHistory() async {
        let clock = ManualClock(now: 0)
        let recorder = RouteFailureRecorder()
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.staySilent(callId: "quiet")]),
        ])
        let summarizer = ScriptedThrowBrain(script: [nil])
        let (driver, transcript) = makeDriver(brain: brain, summarizer: summarizer, clock: clock,
                                              config: Config(historyCompactionTokenThreshold: 5),
                                              onRouteFailure: { recorder.record($0) })
        transcript.append(.init(speaker: .me, text: "a reasonably long problem statement to remember", at: 0))
        await driver.handleTrigger(.turnEnd)
        transcript.append(.init(speaker: .me, text: "next thought", at: 5))
        await driver.handleTrigger(.turnEnd)
        let second = brain.calls[1].compactMap(\.text).joined(separator: "\n")
        #expect(second.contains("a reasonably long problem statement to remember"))
        #expect(recorder.failures.isEmpty)
        // The checks above also pass if compaction never ran, so confirm the summarizer was called.
        #expect(await waitUntilAsync { summarizer.calls.count >= 1 })
        await driver.cancelBackgroundWork()?.value
    }

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

        #expect(outcome == .silentByModel)
        #expect(await waitUntilAsync { await gate.hasEntered })
        await gate.release()
        await driver.cancelBackgroundWork()?.value
    }

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

        let drained = driver.cancelBackgroundWork()
        #expect(drained != nil)
        await gate.release()
        await drained?.value

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

    @Test func consecutiveTurnsBothReachBrain() async {
        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", lines: ["first"])])])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "first idea about the grid", at: 100))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        transcript.append(.init(speaker: .me, text: "second idea about the rows", at: 101))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(brain.calls.count == 2)
        #expect(overlay.rendered.count == 2)
    }

    @Test func incompleteResponsesEndCycleWithoutRenderingPartialOutput() async {
        let brain = ScriptedBrain(script: Array(repeating:
            .init(toolCalls: [], rawToolCalls: [], incompleteReason: "max_output_tokens"), count: 4)
            + [.init(toolCalls: [.staySilent(callId: "complete")])])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: ManualClock())
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(brain.calls.count == 3)
        #expect(overlay.rendered.isEmpty)
    }

    @Test func repeatedToolLoopExhaustionEndsCycle() async {
        // `CoachAttemptRunner.maxToolIterations` times the three attempts a target gets.
        let boundedResponses = 7 * 3
        let brain = ScriptedBrain(script: Array(repeating:
            .init(toolCalls: [.captureScreen(callId: "c")],
                  rawToolCalls: [RawToolCall(id: "c", name: "capture_screen", argumentsJSON: "{}")]),
            count: boundedResponses) + [.init(toolCalls: [.staySilent(callId: "complete")])])
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, overlay: overlay, clock: ManualClock())
        transcript.append(.init(speaker: .me, text: "look at this code", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(brain.calls.count == boundedResponses)
        #expect(overlay.rendered.isEmpty)
    }

    @Test func freshAttemptCarriesOnlyTheLatestScreenObservation() async {
        // `CoachAttemptRunner.maxToolIterations`, so the speak opens a fresh attempt.
        let responsesPerAttempt = 7
        let captures = (0..<responsesPerAttempt).map { index in
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
        #expect(brain.calls.count == responsesPerAttempt + 1)
        let freshAttempt = brain.calls[responsesPerAttempt]
        #expect(freshAttempt.count(where: { $0.imageBase64JPEG != nil }) == 1)
        #expect(freshAttempt.count(where: {
            ($0.text ?? "").contains("latest visible code")
        }) == 1)
        #expect(overlay.rendered == [["bounded context"]])
    }

    @MainActor
    @Test func inFlightSuccessClearsOutageAfterCredentialRefresh() async {
        let recorder = BrainRecoveryRecorder()
        let gate = AsyncGate()
        let original = TwoFailuresThenGatedSuccessBrain(gate: gate)
        let target = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [ConfiguredBrainTarget(target: target, brain: original)],
                onRecoveryChanged: { recorder.providers.append($0) }),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(), automaticAttemptDelay: { _ in })
        transcript.append(.init(speaker: .them, text: "how would you scale this?", at: 0))
        let outcome = Task { await driver.handleTrigger(.turnEnd) }
        #expect(await waitUntilAsync { await gate.hasEntered })
        #expect(recorder.providers == [.openAI, .openAI])
        let replacement = ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "unused")])])
        #expect(driver.refreshBrainRouteClients(ConfiguredBrainRoute(
            targets: [ConfiguredBrainTarget(target: target, brain: replacement)],
            onRecoveryChanged: { recorder.providers.append($0) })))
        await gate.release()
        #expect(await outcome.value == .silentByModel)
        #expect(recorder.providers == [.openAI, .openAI, nil])
        #expect(replacement.calls.isEmpty)
    }

    @MainActor
    @Test func topologyEditKeepsOutageUntilCommittedSuccess() async {
        let recorder = BrainRecoveryRecorder()
        let clock = ManualClock()
        let delays = RecoveryDelayProbe()
        let gate = AsyncGate()
        let original = TwoFailuresThenGatedSuccessBrain(gate: gate)
        let target = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [ConfiguredBrainTarget(target: target, brain: original)],
                onRecoveryChanged: { recorder.providers.append($0) }),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: clock, automaticAttemptDelay: { _ in },
            recoveryDelay: { try await delays.wait($0) })
        transcript.append(.init(speaker: .them, text: "how would you scale this?", at: 0))
        let outcome = Task { await driver.handleTrigger(.turnEnd) }
        #expect(await waitUntilAsync { await gate.hasEntered })
        #expect(recorder.providers == [.openAI, .openAI])
        let replacement = ThrowingBrain()
        driver.updateBrainRoute(ConfiguredBrainRoute(
            targets: [ConfiguredBrainTarget(target: BrainTarget(provider: .codexSubscription, modelID: "gpt-5.5"), brain: replacement)],
            onRecoveryChanged: { recorder.providers.append($0) }))
        #expect(recorder.providers == [.openAI, .openAI])
        clock.set(100)
        await gate.release()
        #expect(await outcome.value == .silentByModel)
        #expect(recorder.providers == [.openAI, .openAI, nil])
        #expect(replacement.callCount == 0)
        clock.set(650)
        // The replacement's first failed cycle starts a new streak, so its ceiling is a full one.
        #expect(await driver.handleTrigger(.manualHint) == .brainError)
        #expect(await waitUntilAsync { await delays.durations == [600] })
        driver.cancelBackgroundWork()
    }

    @MainActor
    @Test(arguments: [false, true])
    func refreshedRouteReportsOutageAndRecovery(reconfigure: Bool) async {
        let recorder = BrainRecoveryRecorder()
        let target = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [ConfiguredBrainTarget(
                target: target, brain: ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "old")])]))]),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(), automaticAttemptDelay: { _ in })
        let replacement = ConfiguredBrainRoute(targets: [ConfiguredBrainTarget(
            target: target, brain: ScriptedThrowBrain(script: [nil, nil,
                .init(toolCalls: [.staySilent(callId: "recovered")])]))],
            onRecoveryChanged: { recorder.providers.append($0) })
        #expect(reconfigure
            ? driver.reconfigureBrainRouteClients(replacement)
            : driver.refreshBrainRouteClients(replacement))
        transcript.append(.init(speaker: .them, text: "how would you scale this?", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        #expect(recorder.providers == [.openAI, .openAI, nil])
    }

    @Test func unavailableFallbackDoesNotEndRecoverableSession() async {
        let brain = ScriptedThrowBrain(script: [nil, nil, nil, nil,
            .init(toolCalls: [.speak(callId: "recovered", lines: ["Use the latest question."])])])
        let primary = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let unavailable = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [
                ConfiguredBrainTarget(target: primary, brain: brain),
                ConfiguredBrainTarget(unavailable: unavailable, failure: unavailableFailure(unavailable, "signed out")),
            ]),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(), automaticAttemptDelay: { _ in })
        transcript.append(.init(speaker: .them, text: "how would you scale this?", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(brain.calls.count == 3)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(brain.calls.count == 5)
    }

    @Test func failedCycleReportsOneNoticeAndLaterCycleCanRecover() async throws {
        let recorder = RouteFailureRecorder()
        let brain = ScriptedThrowBrain(script: [
            nil, nil, nil, nil, nil,
            .init(toolCalls: [.speak(callId: "recovered", lines: ["Use the latest question."])]),
        ])
        let overlay = FakeOverlay()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (activityLog, activity) = ActivityLog.recordingSession(in: directory)
        defer { activityLog.disable(); try? FileManager.default.removeItem(at: directory) }
        let (driver, transcript) = makeDriver(
            activity: activity, brain: brain, overlay: overlay, clock: ManualClock(),
            onRouteFailure: { recorder.record($0) })
        transcript.append(.init(speaker: .them, text: "How would you design a queue?", at: 0))

        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(brain.calls.count == 3)
        transcript.append(.init(speaker: .them, text: "Please try the queue question again.", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        #expect(brain.calls.count == 6)
        #expect(recorder.failures.count == 1)
        #expect(overlay.rendered == [["Use the latest question."]])
        _ = await activity.close()
        let rows = try String(contentsOf: directory.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        #expect(rows.components(separatedBy: "\n").filter { $0.contains("coachingTurnFailed") }.count == 1)
    }

    @Test func failedCycleStopsAfterThreeAttemptsAndLaterCycleGetsFreshBudget() async {
        let brain = ScriptedThrowBrain(script: [nil, nil, nil, nil, nil,
            .init(toolCalls: [.staySilent(callId: "later")])])
        let recorder = RouteFailureRecorder()
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock(),
            onRouteFailure: { recorder.record($0) })
        transcript.append(.init(speaker: .them, text: "first question", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(brain.calls.count == 3)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 60)) == .brainError)
        #expect(brain.calls.count == 3)
        transcript.append(.init(speaker: .them, text: "new question", at: 60))
        #expect(await driver.handleTrigger(.turnEnd) == .silentByModel)
        #expect(brain.calls.count == 6)
        #expect(recorder.failures.count == 1)
    }

    @Test(arguments: [false, true], [TriggerReason.turnEnd, .manualHint, .manualExplanation, .manualCode])
    func newInputDuringFinalAttemptGetsItsOwnCycleBudget(unavailableTail: Bool, reason: TriggerReason) async {
        let gate = AsyncGate()
        let brain = TwoFailuresThenGatedFailureBrain(gate: gate)
        let recorder = RouteFailureRecorder()
        let transcript = RollingTranscript()
        var targets = [ConfiguredBrainTarget(target: BrainTarget(provider: .openAI, modelID: "gpt-5.5"), brain: brain)]
        if unavailableTail {
            targets.append(ConfiguredBrainTarget(unavailable: BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5"), failure: brainFailure(.permanent, "signed out", provider: .claudeSubscription)))
        }
        let driver = CoachDriver(config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: targets, onExhausted: { _, failure in recorder.record(failure) }),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(), automaticAttemptDelay: { _ in })
        transcript.append(.init(speaker: .them, text: "first question", at: 0))
        let request = Task { await driver.handleTrigger(.turnEnd) }
        #expect(await waitUntilAsync { await gate.hasEntered })
        if !reason.isManual { transcript.append(.init(speaker: .them, text: "a genuinely new question", at: 1)) }
        #expect(await driver.handleTrigger(reason) == .busy)
        await gate.release()
        #expect(await request.value == .brainError)
        #expect(brain.callCount == 6)
        #expect(recorder.failures.count == 2)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 60)) == .brainError)
        #expect(brain.callCount == 6)
    }

    @Test(arguments: [TriggerReason.manualHint, .manualExplanation, .manualCode])
    func manualHintCanRetryFailedCycleWithoutNewSpeech(reason: TriggerReason) async {
        let brain = ScriptedThrowBrain(script: [nil, nil, nil,
            .init(toolCalls: [.speak(callId: "later", lines: ["Use the latest question."])])])
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock())
        transcript.append(.init(speaker: .them, text: "a question", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(await driver.handleTrigger(reason) == .spoke)
        #expect(brain.calls.count == 4)
    }

    @Test func permanentTargetIsExcludedFromLaterCycles() async {
        let primary = ThrowingBrain(error: brainFailure(.permanent, "invalid key"))
        let fallback = ScriptedThrowBrain(script: [nil, nil, nil,
            .init(toolCalls: [.speak(callId: "recovered", lines: ["Use the latest question."])])])
        let (driver, transcript) = makeRouteDriver([
            (BrainTarget(provider: .openAI, modelID: "gpt-5.5"), primary),
            (BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5"), fallback),
        ])
        defer { driver.cancelBackgroundWork() }
        transcript.append(.init(speaker: .them, text: "first question", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(primary.callCount == 1)
        #expect(fallback.calls.count == 4)
    }

    @Test func allPermanentTargetsEndSessionOnceAndRetainCause() async {
        let recorder = RouteFailureRecorder()
        let clock = ManualClock()
        let brain = ThrowingBrain(error: brainFailure(.permanent, "invalid key"))
        let transcript = RollingTranscript()
        let driver = CoachDriver(config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [ConfiguredBrainTarget(
                target: BrainTarget(provider: .openAI, modelID: "gpt-5.5"), brain: brain)],
                onTerminated: { _, failure in recorder.record(failure) }),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: clock, automaticAttemptDelay: { _ in })
        #expect(await driver.handleTrigger(.manualHint) == .brainError)
        #expect(await driver.handleTrigger(.manualHint) == .brainError)
        #expect(brain.callCount == 1)
        #expect(recorder.failures.count == 1)
        #expect(recorder.failures.first?.message == "invalid key")
    }

    @Test func failedCycleDeadlineEndsSessionWithTheLatestFailure() async {
        let clock = ManualClock()
        let deadline = AsyncGate()
        let expired = RouteFailureRecorder()
        let exhausted = RouteFailureRecorder()
        let brain = ScriptedThrowBrain(
            script: [nil, nil, nil, .init(toolCalls: [])],
            error: brainFailure(.temporary, "first outage"))
        let driver = CoachDriver(config: .default, transcript: RollingTranscript(),
            route: ConfiguredBrainRoute(targets: [ConfiguredBrainTarget(
                target: BrainTarget(provider: .openAI, modelID: "gpt-5.5"), brain: brain)],
                onTerminated: { _, failure in exhausted.record(failure) },
                onRecoveryExpired: { expired.record($0) }),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: clock, automaticAttemptDelay: { _ in },
            recoveryDelay: { _ in await deadline.enter() })
        defer { driver.cancelBackgroundWork() }
        #expect(await driver.handleTrigger(.manualHint) == .brainError)
        #expect(await driver.handleTrigger(.manualHint) == .brainError)
        await deadline.waitUntilEntered()
        clock.set(600)
        await deadline.release()
        #expect(await waitUntilAsync { expired.failures.count == 1 })
        #expect(expired.messages == ["provider returned no required coaching tool call"])
        #expect(exhausted.failures.isEmpty)
        #expect(brain.calls.count == 6)
    }

    @Test func firstFailureAfterLongQuietKeepsTheSession() async {
        let clock = ManualClock()
        let delays = RecoveryDelayProbe()
        let ended = RouteFailureRecorder()
        let brain = ThrowingBrain(error: brainFailure(.temporary, "provider timed out"))
        let driver = CoachDriver(config: .default, transcript: RollingTranscript(),
            route: ConfiguredBrainRoute(targets: [ConfiguredBrainTarget(
                target: BrainTarget(provider: .openAI, modelID: "gpt-5.5"), brain: brain)],
                onTerminated: { _, failure in ended.record(failure) },
                onRecoveryExpired: { ended.record($0) }),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: clock, automaticAttemptDelay: { _ in },
            recoveryDelay: { seconds in try await delays.wait(seconds) })
        defer { driver.cancelBackgroundWork() }
        clock.set(1_440)
        #expect(await driver.handleTrigger(.manualHint) == .brainError)
        #expect(await waitUntilAsync { await delays.durations == [600] })
        #expect(await driver.handleTrigger(.manualHint) == .brainError)
        #expect(brain.callCount == 6)
        #expect(ended.failures.isEmpty)
    }

    @Test func successCancelsDeadlineAndTheNextStreakRestartsTheCeiling() async {
        let clock = ManualClock()
        let delays = RecoveryDelayProbe()
        let recorder = RouteFailureRecorder()
        let brain = ScriptedThrowBrain(script: [nil, nil, nil,
            .init(toolCalls: [.speak(callId: "recovered", lines: ["Use the latest question."])]), nil, nil, nil])
        let driver = CoachDriver(config: .default, transcript: RollingTranscript(),
            route: ConfiguredBrainRoute(targets: [ConfiguredBrainTarget(
                target: BrainTarget(provider: .openAI, modelID: "gpt-5.5"), brain: brain)],
                onTerminated: { _, failure in recorder.record(failure) }),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: clock, automaticAttemptDelay: { _ in },
            recoveryDelay: { seconds in try await delays.wait(seconds) })
        defer { driver.cancelBackgroundWork() }
        #expect(await driver.handleTrigger(.manualHint) == .brainError)
        #expect(await waitUntilAsync { await delays.durations == [600] })
        clock.set(100)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(await waitUntilAsync { await delays.cancellations == 1 })
        clock.set(650)
        #expect(await driver.handleTrigger(.manualHint) == .brainError)
        #expect(await waitUntilAsync { await delays.durations == [600, 600] })
        #expect(recorder.failures.isEmpty)
    }

    @Test func cycleCooldownCoalescesManualAndNewSpeechBeforeSnapshot() async {
        let clock = ManualClock()
        let cooldown = AsyncGate()
        let brain = ScriptedThrowBrain(script: [nil, nil, nil, nil, nil, nil,
            .init(toolCalls: [.speak(callId: "recovered", lines: ["Use the latest question."])])])
        let transcript = RollingTranscript()
        let driver = CoachDriver(config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [ConfiguredBrainTarget(
                target: BrainTarget(provider: .openAI, modelID: "gpt-5.5"), brain: brain)]),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: clock, automaticAttemptDelay: { _ in },
            recoveryDelay: { seconds in
                if seconds == 5 { await cooldown.enter() }
                else { try await Task.sleep(for: .seconds(3_600)) }
            })
        defer { driver.cancelBackgroundWork() }
        #expect(await driver.handleTrigger(.manualHint) == .brainError)
        #expect(await driver.handleTrigger(.manualHint) == .brainError)
        let next = Task { await driver.handleTrigger(.manualHint) }
        await cooldown.waitUntilEntered()
        #expect(brain.calls.count == 6)
        transcript.append(.init(speaker: .them, text: "newest question during cooldown", at: 5))
        #expect(await driver.handleTrigger(.turnEnd, transcriptBoundary: transcript.count) == .busy)
        clock.set(5)
        await cooldown.release()
        #expect(await next.value == .spoke)
        #expect(brain.calls.count == 7)
        #expect(brain.calls.last?.contains { ($0.text ?? "").contains("newest question during cooldown") } == true)
    }

    @Test func permanentBrainErrorOutcome() async {
        let brain = ThrowingBrain(error: brainFailure(.permanent, "invalid credentials"))
        let (driver, transcript) = makeDriver(brain: brain, clock: ManualClock())
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        #expect(await driver.handleTrigger(.turnEnd) == .brainError)
        #expect(brain.callCount == 1)
    }

    @Test func stopCancelsFastRetry() async {
        let recorder = RouteFailureRecorder()
        let brain = ThrowingBrain()
        let delayProbe = AutomaticDelayProbe()
        let (driver, transcript) = makeDriver(
            brain: brain, clock: ManualClock(),
            automaticAttemptDelay: { sequence in
                if sequence >= 2 { try await delayProbe.waitForCancellation() }
            },
            onRouteFailure: { recorder.record($0) })
        transcript.append(.init(speaker: .me, text: "please help with this problem", at: 0))
        let outcome = Task { await driver.handleTrigger(.turnEnd) }
        #expect(await waitUntilAsync { await delayProbe.hasEntered })
        outcome.cancel()
        #expect(await outcome.value == .cancelled)
        #expect(recorder.failures.isEmpty)
        #expect(brain.callCount == 2)
    }

    @Test func newSpeechWakesFastRetryWithLatestTranscript() async {
        let gate = AsyncGate()
        let brain = ScriptedThrowBrain(script: [nil, nil,
            .init(toolCalls: [.speak(callId: "complete", lines: ["Latest answer."])])])
        let (driver, transcript) = makeDriver(
            brain: brain, clock: ManualClock(),
            automaticAttemptDelay: { sequence in
                if sequence == 2 {
                    await withTaskCancellationHandler { await gate.enter() }
                    onCancel: { Task { await gate.release() } }
                }
            })
        transcript.append(.init(speaker: .them, text: "first question", at: 0))
        let outcome = Task { await driver.handleTrigger(.turnEnd) }
        defer { outcome.cancel() }
        #expect(await waitUntilAsync { await gate.hasEntered })
        transcript.append(.init(speaker: .them, text: "latest follow-up question", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .busy)
        await gate.release()
        #expect(await outcome.value == .spoke)
        #expect(brain.calls.count == 3)
        #expect(brain.calls.last?.contains { ($0.text ?? "").contains("latest follow-up question") } == true)
    }

    @Test func providerTimeoutSchedulesFreshAttemptWithoutNaturalTrigger() async {
        let recorder = RouteFailureRecorder()
        let brain = TimeoutThenSpeakingBrain()
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(
            brain: brain, brainProvider: .codexSubscription, overlay: overlay,
            clock: ManualClock(now: 0),
            onRouteFailure: { recorder.record($0) }
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
        let recorder = RouteFailureRecorder()
        let (driver, transcript) = makeDriver(
            brain: brain, brainProvider: .openAI, overlay: overlay,
            clock: ManualClock(now: 0),
            onRouteFailure: { recorder.record($0) }
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

    @Test func everyAudioTurnRequiresAToolCall() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", lines: ["hi"])])])
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "let me think this through", at: 0))
        await driver.handleTrigger(.turnEnd)
        #expect(brain.toolChoices.last == .required)
    }

    @Test func concurrentTriggerIsBusyThenCoalesced() async {
        let clock = ManualClock(now: 0)
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, response: .init(toolCalls: [.speak(callId: "s1", lines: ["hi"])]))
        let (driver, transcript) = makeDriver(brain: brain, clock: clock)
        transcript.append(.init(speaker: .me, text: "first idea about the grid", at: 0))
        async let first = driver.handleTrigger(.turnEnd)
        await gate.waitUntilEntered()
        transcript.append(.init(speaker: .me, text: "second idea about the rows", at: 1))
        let second = await driver.handleTrigger(.turnEnd)
        #expect(second == .busy)
        await gate.release()
        _ = await first
        #expect(brain.callCount >= 2)
    }

    /// A delayed transcript callback lands after the parked attempt already sent its line.
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

/// Synchronous on purpose: blocking the main actor holds route delivery at a deterministic point.
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
    func record(target: BrainTarget, failure: ProviderFailure) {
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

/// @unchecked: all mutable state is guarded by `lock`.
final class ThrowingBrain: BrainClient, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error
    private var calls = 0
    private var preparations = 0
    var callCount: Int { lock.withLock { calls } }
    var preparationCount: Int { lock.withLock { preparations } }

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
}

/// @unchecked: `lock` guards the call count.
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

/// @unchecked: `lock` guards the call count.
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

/// @unchecked: `lock` guards the call count.
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
final class RouteFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ProviderFailure] = []
    var failures: [ProviderFailure] { lock.lock(); defer { lock.unlock() }; return recorded }
    var messages: [String] { failures.map(\.message) }
    func record(_ failure: ProviderFailure) { lock.lock(); recorded.append(failure); lock.unlock() }
}

/// @unchecked: `CoachDriver` awaits one `respond` at a time, so `calls` never races.
final class TimeoutThenSpeakingBrain: BrainClient, @unchecked Sendable {
    private(set) var calls: [[ChatMessage]] = []

    func respond(messages: [ChatMessage], tools: [ToolDef],
                 toolChoice: ToolChoice) async throws -> BrainResponse {
        calls.append(messages)
        if calls.count == 1 {
            throw URLError(.timedOut)
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

/// @unchecked: all mutable state is guarded by `lock`.
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

/// @unchecked: `recordedCalls` is only accessed under `lock`.
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

/// @unchecked: `recordedCalls` is only accessed under `lock`.
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

/// @unchecked: `lock` guards `calls` against the detached compaction task and the polling test.
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
        // Release on cancellation: `AsyncGate` parks on a plain continuation, which would hang a
        // cancelled task group instead of failing the test.
        await withTaskCancellationHandler {
            await gate.enter()
        } onCancel: {
            Task { await gate.release() }
        }
        return BrainResponse(toolCalls: [], outputText: summary)
    }
}

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

@MainActor
private final class BrainRecoveryRecorder {
    var providers: [BrainProvider?] = []
}

private actor RecoveryDelayProbe {
    private(set) var durations: [TimeInterval] = []
    private(set) var cancellations = 0

    func wait(_ seconds: TimeInterval) async throws {
        durations.append(seconds)
        do { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
        catch { cancellations += 1; throw error }
    }
}
