import Foundation
import Testing
@testable import JarvisCore

/// Mock brain: replays a script of responses and records the messages it saw on each call.
final class ScriptedBrain: BrainClient, @unchecked Sendable {
    private(set) var calls: [[ChatMessage]] = []
    let script: [BrainResponse]
    init(script: [BrainResponse]) { self.script = script }
    func respond(messages: [ChatMessage], tools: [ToolDef]) async throws -> BrainResponse {
        calls.append(messages)
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

    /// End-to-end: a real capture→speak turn through the production `CoachDriver` with the activity
    /// log enabled (as dev mode does). Proves the screenshot the model looked at lands in the
    /// activity log as a genuine, owner-only JPEG rendered as a clickable thumbnail linked to the
    /// full image — the behaviour verified by hand, now automated against regressions.
    ///
    /// `.serialized` + `disable()` teardown because it drives the shared `ActivityLog` singleton.
    @Test(.serialized) func screenshotLandsInActivityLogAsValidJpeg() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-e2e-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { ActivityLog.shared.disable(); try? FileManager.default.removeItem(at: dir) }
        ActivityLog.shared.enable(directory: dir)

        let clock = ManualClock(now: 100)
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c1")],
                  rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")]),
            .init(toolCalls: [.speak(callId: "s1", text: "Watch the off-by-one there.")],
                  rawToolCalls: [RawToolCall(id: "s1", name: "speak",
                                             argumentsJSON: #"{"text":"Watch the off-by-one there."}"#)]),
        ])
        let screen = FakeScreen(payload: TestFixtures.tinyJpegBase64)   // a real JPEG, like screencapture
        let (driver, transcript) = makeDriver(brain: brain, screen: screen, overlay: FakeOverlay(),
                                              clock: clock, guardrails: guardrails)
        transcript.append(.init(speaker: .me, text: "here's my solution", at: 100))

        await driver.handleTrigger(.turnEnd)

        // Reading htmlURL drains the activity log's serial write queue (a sync barrier after the
        // async record() calls), so everything is on disk before we assert.
        let html = try String(contentsOf: try #require(ActivityLog.shared.htmlURL), encoding: .utf8)
        #expect(html.contains("looking at your screen"))   // the capture line
        #expect(html.contains("<img src=\"shot-"))          // rendered thumbnail
        #expect(html.contains("target=\"_blank\""))         // click → full image in a new tab

        // Find the saved screenshot and prove it round-tripped as a genuine JPEG (SOI/EOI intact),
        // owner-only. Scan rather than hard-code shot-1 so a concurrent test sharing the singleton
        // can't break us.
        let shots = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("shot-") && $0.pathExtension == "jpg" }
        let shot = try #require(try shots.first { url in
            let d = try Data(contentsOf: url)
            return d.prefix(2) == Data([0xFF, 0xD8]) && d.suffix(2) == Data([0xFF, 0xD9])
        }, "expected a valid-JPEG screenshot in the activity log dir")
        #expect(try Data(contentsOf: shot) == TestFixtures.tinyJpeg)   // bytes preserved exactly
        let perms = try FileManager.default.attributesOfItem(atPath: shot.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
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
}
