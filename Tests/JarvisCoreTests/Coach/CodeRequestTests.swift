import Foundation
import Testing
@testable import JarvisCore

@Suite struct CodeRequestTests {
    @Test(arguments: [TriggerReason.turnEnd, .manualHint, .manualExplanation])
    func disabledTriggersCannotDeliverCode(_ reason: TriggerReason) async throws {
        let snippet = try #require(CodeSnippet(language: "Python", placement: "Inside your loop", code: "seen[ch] = right"))
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["Remember this position."], codeSnippet: snippet)])])
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .me, text: "I am stuck with the loop", at: 0))
        let sink = CodeRequestSink()
        let driver = makeDriver(brain, transcript, sink)
        #expect(await driver.handleTrigger(reason) == .spoke)
        #expect(sink.codeUpdates == [nil])
        #expect(sink.lines == ["Remember this position."])
    }

    @Test func manualCodeUsesCurrentContextAndWorksWithExplanationsDisabled() async throws {
        let snippet = try #require(CodeSnippet(language: "Python", placement: "Inside your loop", code: "seen[ch] = right"))
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "s", lines: ["Remember this position."], codeSnippet: snippet)]),
            .init(toolCalls: [.speak(callId: "s2", lines: ["Your approach needs a different data structure."])])
        ])
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .them, text: "Find the longest substring without repeats", at: 0))
        transcript.append(.init(speaker: .me, text: "I used seen and left, but got stuck in the loop", at: 1))
        let sink = CodeRequestSink()
        let screen = FakeScreen()
        let driver = makeDriver(brain, transcript, sink, screen: screen, codeEnabled: true, explanationsEnabled: false)
        #expect(await driver.handleTrigger(.manualCode) == .spoke)
        #expect(sink.codeUpdates.count == 1)
        #expect((sink.codeUpdates.last ?? nil) == snippet)
        #expect(screen.captureCount == 1)
        #expect(brain.toolChoices.last == .force("speak"))
        #expect(brain.calls[0].contains { $0.imageBase64JPEG != nil })
        #expect(brain.calls[0].contains { $0.text?.contains("seen and left") == true })
        #expect(await driver.handleTrigger(.manualCode) == .spoke)
        #expect(sink.codeUpdates.count == 2)
        #expect((sink.codeUpdates.last ?? nil) == nil)
    }

    @Test(arguments: [TriggerReason.turnEnd, .manualHint, .manualExplanation])
    func enabledHintsDeliverMatchingCodeAndClearOnNextHint(_ reason: TriggerReason) async throws {
        let snippet = try #require(CodeSnippet(language: "Python", placement: "In loop", code: "seen[ch] = right"))
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.speak(callId: "one", lines: ["Remember the position"], codeSnippet: snippet)]),
            .init(toolCalls: [.speak(callId: "two", lines: ["Reconsider the approach"])])])
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .me, text: "I am stuck implementing the loop", at: 0))
        let sink = CodeRequestSink()
        let driver = makeDriver(brain, transcript, sink, codeEnabled: true)
        #expect(await driver.handleTrigger(reason) == .spoke)
        #expect(sink.codeUpdates.count == 1)
        #expect((sink.codeUpdates.last ?? nil) == snippet)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(sink.codeUpdates.count == 2)
        #expect((sink.codeUpdates.last ?? nil) == nil)
    }

    @Test(arguments: [TriggerReason.manualHint, .manualCode])
    func generalTechnicalSessionsCanDeliverCode(_ reason: TriggerReason) async throws {
        let code = try #require(CodeSnippet(language: "Python", placement: "Start", code: "seen = {}"))
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["Initialize state"], codeSnippet: code)])])
        let sink = CodeRequestSink()
        let driver = makeDriver(brain, RollingTranscript(), sink, format: .generalTechnical, codeEnabled: true)
        #expect(await driver.handleTrigger(reason) == .spoke)
        #expect(sink.codeUpdates == [code])
        #expect(brain.calls.count == 1)
    }

    @Test func codePreferenceDefaultsOffAndPersistsIndependently() {
        let suite = "CodePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let code = CodePreferences(defaults: defaults)
        #expect(!code.isEnabled)
        code.isEnabled = true
        #expect(CodePreferences(defaults: defaults).isEnabled)
        ExplanationPreferences(defaults: defaults).isEnabled = false
        #expect(code.isEnabled)
        code.isEnabled = false
        #expect(!CodePreferences(defaults: defaults).isEnabled)
    }

    @Test(arguments: [true, false])
    func codeCapabilityAndPromptRemainFixedAcrossPlanEdits(_ enabled: Bool) async throws {
        let snippet = try #require(CodeSnippet(language: "Python", placement: "Start", code: "seen = {}"))
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["Initialize state"], codeSnippet: snippet)])])
        let sink = CodeRequestSink()
        let driver = makeDriver(brain, RollingTranscript(), sink, codeEnabled: enabled)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        driver.updatePlan(SessionPlan(revision: 1, screen: SessionPlan.default.screen, codeEnabled: !enabled))
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(sink.codeUpdates == [enabled ? snippet : nil, enabled ? snippet : nil])
        #expect(brain.calls[0].first?.text == brain.calls[1].first?.text)
        #expect(brain.calls[0].first?.text?.contains("# Code accompanies") == enabled)
        let restarted = makeDriver(brain, RollingTranscript(), sink, codeEnabled: !enabled)
        #expect(await restarted.handleTrigger(.manualHint) == .spoke)
        #expect((sink.codeUpdates.last ?? nil) == (enabled ? nil : snippet))
    }

    @Test(arguments: [InterviewFormat.behavioral, .systemDesign])
    func enabledNonCodingHintsStillSuppressCode(_ format: InterviewFormat) async throws {
        let code = try #require(CodeSnippet(language: "Python", placement: "Start", code: "seen = {}"))
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "one", lines: ["Consider the requirements"], codeSnippet: code)])])
        let sink = CodeRequestSink()
        let driver = makeDriver(brain, RollingTranscript(), sink, format: format, codeEnabled: true)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(sink.codeUpdates == [nil])
    }

    @Test(arguments: [true, false])
    func deliveredHistoryKeepsOnlyEnabledCodeWhenExplanationsAreOff(_ enabled: Bool) async throws {
        let args = #"{"lines":["Initialize state"],"explanation":"Hidden detail","codeSnippet":{"language":"Python","placement":"Start","code":"seen = {}","highlightedLines":[]}}"#
        let response = BrainResponse(toolCalls: [try #require(ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON: args))],
            rawToolCalls: [.init(id: "s", name: "speak", argumentsJSON: args)])
        let brain = ScriptedBrain(script: [response, response])
        let driver = makeDriver(brain, RollingTranscript(), CodeRequestSink(), codeEnabled: enabled, explanationsEnabled: false)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        let call = try #require(brain.calls.last?.flatMap { $0.toolCalls ?? [] }.first { $0.name == "speak" })
        let object = try #require(JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        #expect(object["explanation"] is NSNull)
        if enabled { #expect((object["codeSnippet"] as? [String: Any])?["code"] as? String == "seen = {}") }
        else { #expect(object["codeSnippet"] is NSNull) }
    }

    @Test @MainActor func hidingBoxDuringCodeRequestScrubsHistory() async throws {
        let args = #"{"lines":["Initialize state"],"codeSnippet":{"language":"Python","placement":"Start","code":"seen = {}","highlightedLines":[]}}"#
        let response = BrainResponse(toolCalls: [try #require(ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON: args))],
            rawToolCalls: [.init(id: "s", name: "speak", argumentsJSON: args)])
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, response: response)
        let sink = CodeRequestSink()
        let driver = makeDriver(brain, RollingTranscript(), sink, codeEnabled: true)
        let task = Task { await driver.handleTrigger(.manualCode) }
        await gate.waitUntilEntered()
        sink.acceptsDetail = false
        await gate.release()
        #expect(await task.value == .spoke)
        #expect(sink.codeUpdates == [nil])
        sink.acceptsDetail = true
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect((sink.codeUpdates.last ?? nil)?.code == "seen = {}")
        let call = try #require(brain.calls.last?.flatMap { $0.toolCalls ?? [] }.first { $0.name == "speak" })
        let object = try #require(JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        #expect(object["codeSnippet"] is NSNull)
    }

    @Test func malformedCodeRetainsUsefulHint() throws {
        let payloads = ["null", "42", #"{"language":"Python","placement":"In loop","code":" ","highlightedLines":[]}"#,
            #"{"language":"Python","placement":"In loop","code":"x = 1","highlightedLines":"bad"}"#]
        for payload in payloads {
            let call = ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON: "{\"lines\":[\"Continue here\"],\"codeSnippet\":\(payload)}")
            guard case .speak(_, let lines, _, _, let snippet) = call else { Issue.record("Lost the hint"); continue }
            #expect(lines == ["Continue here"])
            #expect(snippet == nil)
        }
    }

    @Test func codeHotkeyPersistsIndependently() {
        let suite = "CodeRequestTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let code = HotkeyPreferences(defaults: defaults, shortcut: .showCode)
        let hint = HotkeyPreferences(defaults: defaults, shortcut: .hint)
        let explain = HotkeyPreferences(defaults: defaults, shortcut: .explainMore)
        let saved = HotkeyCombination(keyCode: 12, modifiers: [.command, .shift])
        code.combination = saved
        #expect(HotkeyPreferences(defaults: defaults, shortcut: .showCode).combination == saved)
        #expect(hint.combination == Defaults.Hotkey.combination)
        #expect(explain.combination == Defaults.Hotkey.explanationCombination)
    }

    @Test(arguments: [InterviewFormat.behavioral, .systemDesign])
    func nonCodingSessionsExplainUnavailabilityWithoutModelWork(_ format: InterviewFormat) async {
        let brain = ScriptedBrain(script: [])
        let sink = CodeRequestSink()
        let screen = FakeScreen()
        let driver = makeDriver(brain, RollingTranscript(), sink, screen: screen, format: format,
                                activity: UnexpectedCodeActivity())
        #expect(await driver.handleTrigger(.manualCode) == .spoke)
        #expect(brain.calls.isEmpty)
        #expect(screen.captureCount == 0)
        #expect(sink.lines.first?.contains("Coding") == true)
    }

    @Test func validCodeParsingPreservesIndentationAndRejectsOversizedComponent() throws {
        let snippet: [String: Any] = ["language": "Python", "placement": "Inside your loop",
            "code": "    if ch in seen:\n        left = max(left, seen[ch] + 1)", "highlightedLines": [2]]
        for oversized in [false, true] {
            var value = snippet
            if oversized { value["code"] = Array(repeating: "x = 1", count: 13).joined(separator: "\n") }
            let json = try JSONSerialization.data(withJSONObject: ["lines": ["Keep the left edge moving forward."], "codeSnippet": value])
            let call = ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON: String(decoding: json, as: UTF8.self))
            guard case .speak(_, let lines, _, _, let code) = call else { Issue.record("Expected hint"); continue }
            #expect(lines.count == 1)
            if oversized { #expect(code == nil) }
            else {
                #expect(code?.code.hasPrefix("    if") == true)
                #expect(code?.highlightedLines == [2])
            }
        }
    }

    @Test func captureFailureStillAllowsFirstComponentFromKnownContext() async throws {
        let snippet = try #require(CodeSnippet(language: "Python", placement: "Start window state", code: "seen = {}\nleft = 0"))
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["Start with window state."], codeSnippet: snippet)])])
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .them, text: "Find the longest substring without repeats", at: 0))
        let sink = CodeRequestSink()
        let driver = makeDriver(brain, transcript, sink, screen: MissingCodeScreen(), codeEnabled: true)
        #expect(await driver.handleTrigger(.manualCode) == .spoke)
        #expect((sink.codeUpdates.last ?? nil) == snippet)
        #expect(brain.calls[0].contains { $0.text?.contains("failed") == true })
    }

    private func makeDriver(_ brain: BrainClient, _ transcript: RollingTranscript, _ sink: OverlayRendering,
                            screen: ScreenCapturing = FakeScreen(), format: InterviewFormat? = nil,
                            codeEnabled: Bool = false, explanationsEnabled: Bool = true,
                            activity: (any ActivityEventRecording)? = nil) -> CoachDriver {
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        return CoachDriver(config: .default, transcript: transcript,
            route: .init(targets: [.init(target: target, brain: brain)]),
            screen: screen, overlay: sink, clock: ManualClock(now: 100),
            plan: SessionPlan(revision: 0, screen: SessionPlan.default.screen,
                              explanationsEnabled: explanationsEnabled, codeEnabled: codeEnabled),
            activity: activity, interviewFormat: format)
    }
}

private final class CodeRequestSink: OverlayRendering {
    @MainActor var acceptsDetail = true
    @MainActor func deliverCodeSnippet(_ snippet: CodeSnippet?) -> CodeSnippet? {
        let code = acceptsDetail ? snippet : nil
        codeUpdates.append(code)
        return code
    }
    var codeUpdates: [CodeSnippet?] = []
    var lines: [String] = []
    func render(_ lines: [String], perLineSeconds: [TimeInterval]) { self.lines = lines }
    func showCodeSnippet(_ snippet: CodeSnippet?) { codeUpdates.append(snippet) }
}

private final class MissingCodeScreen: ScreenCapturing, Sendable {
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? { nil }
    func cancelCapture() {}
}

private struct UnexpectedCodeActivity: ActivityEventRecording {
    func record(_ event: ActivityEvent, at date: Date) {
        Issue.record("Unavailable shortcut feedback must not create an orphan Activity row")
    }
}
