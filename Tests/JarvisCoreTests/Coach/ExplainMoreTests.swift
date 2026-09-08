import Foundation
import Testing
@testable import JarvisCore

@Suite struct ExplainMoreTests {
    @Test func parserKeepsExplanationAndIgnoresMalformedOptionalDetail() throws {
        let call = ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON:
            #"{"lines":["Keep a moving range."],"explanation":"  Grow the right edge.\n\nMove the left edge past a repeat.  "}"#)
        guard case .speak(_, let lines, _, let explanation) = call else {
            Issue.record("Expected a speak call"); return
        }
        #expect(lines == ["Keep a moving range."])
        #expect(explanation == "Grow the right edge.\n\nMove the left edge past a repeat.")
        for detail in ["null", "42", "\"   \""] {
            let call = ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON:
                "{\"lines\":[\"Still useful\"],\"explanation\":\(detail)}")
            guard case .speak(_, let lines, _, let explanation) = call else {
                Issue.record("Optional detail must not discard a valid hint"); continue
            }
            #expect(lines == ["Still useful"])
            #expect(explanation == nil)
        }
    }

    @Test func shortcutsPersistIndependentlyAndRejectUnsafeStoredExplanationBinding() {
        let suite = "ExplainMoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hint = HotkeyPreferences(defaults: defaults)
        let explain = HotkeyPreferences(defaults: defaults, shortcut: .explainMore)
        #expect(hint.combination != explain.combination)
        let binding = HotkeyCombination(keyCode: 5, modifiers: [.command, .shift])
        explain.combination = binding
        #expect(HotkeyPreferences(defaults: defaults, shortcut: .explainMore).combination == binding)
        #expect(hint.combination == Defaults.Hotkey.combination)
        explain.combination = HotkeyCombination(keyCode: 5, modifiers: [.shift])
        #expect(explain.combination == Defaults.Hotkey.explanationCombination)
    }

    @Test(arguments: [TriggerReason.manualExplanation, .turnEnd])
    func explanationFlowsThroughHistoryAndOverlayForBothTriggers(_ reason: TriggerReason) async throws {
        let args = #"{"lines":["Track the current range."],"explanation":"A window is the range you are checking.\n\nFor abca, drop the first a when the second a arrives."}"#
        let response = BrainResponse(
            toolCalls: [try #require(ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON: args))],
            rawToolCalls: [.init(id: "s", name: "speak", argumentsJSON: args)])
        let brain = ScriptedBrain(script: [response])
        let transcript = RollingTranscript()
        let box = ExplanationSink()
        let caption = FakeOverlay()
        let screen = FakeScreen()
        let driver = makeDriver(brain: brain, transcript: transcript, screen: screen,
                                overlay: BroadcastOverlay([caption, box]))
        transcript.append(.init(speaker: .them, text: "Find the longest substring without repeats", at: 0))
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        transcript.append(.init(speaker: .me, text: "I don't understand why we move the left edge", at: 1))
        if reason == .manualExplanation { driver.updateTranscriptionWork(true, for: .me) }
        #expect(await driver.handleTrigger(reason) == .spoke)
        let messages = try #require(brain.calls.last)
        #expect(messages.contains { $0.text?.contains("longest substring") == true })
        #expect(messages.contains { $0.text?.contains("left edge") == true })
        #expect(messages.contains { $0.toolCalls?.contains { $0.argumentsJSON.contains("For abca") } == true })
        #expect(caption.rendered.last == ["Track the current range."])
        #expect(box.explanation?.contains("For abca") == true)
        if reason == .manualExplanation {
            #expect(screen.captureCount == 2)
            #expect(brain.toolChoices.last == .force("speak"))
            #expect(messages.contains { $0.imageBase64JPEG != nil })
        } else {
            #expect(brain.toolChoices.last == .required)
        }
    }

    @Test func explanationStillRepliesWhenCaptureFails() async {
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["Use the context we discussed."])])])
        let driver = makeDriver(brain: brain, transcript: RollingTranscript(), screen: MissingExplanationScreen(), overlay: FakeOverlay())
        #expect(await driver.handleTrigger(.manualExplanation) == .spoke)
        #expect(brain.calls.count == 1)
        #expect(brain.calls[0].contains { $0.text?.contains("capture") == true && $0.text?.contains("failed") == true })
    }

    @Test(arguments: [TriggerReason.manualHint, .manualExplanation])
    func latestManualIntentSurvivesNaturalWakeWhileBusy(_ latest: TriggerReason) async throws {
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, response: .init(toolCalls: [.speak(callId: "s", lines: ["Continue."])]))
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .me, text: "Let's work through this problem", at: 0))
        let screen = FakeScreen()
        let driver = makeDriver(brain: brain, transcript: transcript, screen: screen, overlay: FakeOverlay())
        let task = Task { await driver.handleTrigger(.turnEnd) }
        await gate.waitUntilEntered()
        let first: TriggerReason = latest == .manualHint ? .manualExplanation : .manualHint
        #expect(await driver.handleTrigger(first) == .busy)
        #expect(await driver.handleTrigger(latest) == .busy)
        #expect(await driver.handleTrigger(.silence(secondsQuiet: 30)) == .busy)
        await gate.release()
        #expect(await task.value == .spoke)
        try #require(brain.calls.count == 2)
        let userText = brain.calls[1].filter { $0.role == .user }.compactMap(\.text).joined(separator: " ")
        #expect(userText.contains(latest == .manualHint ? "hint shortcut" : "Explain more"))
        #expect(!userText.contains(latest == .manualHint ? "Explain more" : "hint shortcut"))
        #expect(screen.captureCount == 1)
    }

    private func makeDriver(brain: BrainClient, transcript: RollingTranscript,
                            screen: ScreenCapturing, overlay: OverlayRendering) -> CoachDriver {
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        return CoachDriver(config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(targets: [.init(target: target, brain: brain)]),
            screen: screen, overlay: overlay, clock: ManualClock(now: 100))
    }
}

// Read only after the awaited driver finishes delivery, with no concurrent mutations.
private final class ExplanationSink: OverlayRendering {
    var explanation: String?
    func render(_ lines: [String], perLineSeconds: [TimeInterval]) {}
    func render(_ lines: [String], perLineSeconds: [TimeInterval], diagram: DiagramHint?, explanation: String?) {
        self.explanation = explanation
    }
}
private final class MissingExplanationScreen: ScreenCapturing, Sendable {
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? { nil }
    func cancelCapture() {}
}
