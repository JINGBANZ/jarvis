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
    /// This drives the shared `ActivityLog` singleton (the real production path: CoachDriver → jlog →
    /// ActivityLog.shared). Peer tests in this suite also call jlog() and can write into this dir
    /// while it's the active sink — `.serialized` does NOT prevent that (swift-testing's serialization
    /// doesn't isolate a test from its peers). Robustness instead comes from: (1) selecting the shot
    /// by exact byte-match to our fixture, so another test's screenshot can't be mistaken for ours,
    /// and (2) writeHTML() re-rendering the full entry list, so our row survives interleaved writes.
    /// `disable()` in defer resets the singleton afterwards.
    @Test func screenshotLandsInActivityLogAsValidJpeg() async throws {
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
