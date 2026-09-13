import Foundation
import Testing
@testable import JarvisCore

@Suite struct ExplanationReviewRegressionTests {
    @Test(arguments: [true, false])
    func changedManualIntentReplacesCarriedScreenWhileKeepingPrep(_ captureSucceeds: Bool) async throws {
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s", lines: ["Continue."])])])
        let runner = CoachAttemptRunner(config: .default, transcript: RollingTranscript(),
            screen: ReviewScreen(succeeds: captureSucceeds), overlay: FakeOverlay(),
            clock: ManualClock(now: 100), sessionStart: 0, coachingAttempts: nil,
            activity: nil, ledger: CoachTranscriptLedger(),
            capabilities: .default)
        var work = CoachAttemptRunner.PendingCoachingWork(reason: .manualExplanation)
        work.preparedManualReason = .manualHint
        work.screenObservation = [.userImage("stale-image"), .user("stale-ocr")]
        work.prepNotesObservation = .user("retained-prep")
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        _ = await runner.runAttempt(work, using: .init(plan: .default, routeRevision: 0,
            routeTopologyRevision: 0, routeIndex: 0, target: target, brain: brain,
            summarizer: nil, onSelected: nil, prepMaterial: nil))
        let messages = try #require(brain.calls.first)
        #expect(!messages.contains { $0.imageBase64JPEG == "stale-image" || $0.text == "stale-ocr" })
        #expect(messages.filter { $0.text == "retained-prep" }.count == 1)
        #expect(messages.compactMap(\.imageBase64JPEG) == (captureSucceeds ? ["fresh-image"] : []))
    }

    @Test func unexecutedSpeakIsNotReplayedAsDelivered() async throws {
        let shown = #"{"lines":["Shown hint."],"explanation":"Hidden detail."}"#
        let unexecuted = #"{"lines":["Unexecuted hint."],"explanation":"Unexecuted detail."}"#
        let calls = [RawToolCall(id: "shown", name: "speak", argumentsJSON: shown),
                     RawToolCall(id: "extra", name: "speak", argumentsJSON: unexecuted)]
        let response = BrainResponse(toolCalls: calls.compactMap {
            ToolInvocation.parse(callId: $0.id, name: $0.name, argumentsJSON: $0.argumentsJSON)
        }, rawToolCalls: calls)
        let brain = ScriptedBrain(script: [response])
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let driver = CoachDriver(config: .default, transcript: RollingTranscript(),
            route: ConfiguredBrainRoute(targets: [.init(target: target, brain: brain)]),
            screen: ReviewScreen(succeeds: true), overlay: FakeOverlay(), clock: ManualClock(now: 100),
            plan: SessionPlan(revision: 0, screen: SessionPlan.default.screen, explanationsEnabled: false))
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        let history = try #require(brain.calls.last).flatMap { $0.toolCalls ?? [] }
        #expect(history.map(\.id) == ["shown"])
        let call = try #require(history.first)
        let object = try #require(JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        #expect(object["explanation"] is NSNull)
        #expect(object["lines"] as? [String] == ["Shown hint."])
    }

    @Test @MainActor func hidingBoxDuringRequestScrubsDeliveredHistory() async throws {
        let args = #"{"lines":["Keep this hint."],"explanation":"Hidden explanation."}"#
        let response = BrainResponse(toolCalls: [try #require(ToolInvocation.parse(
            callId: "s", name: "speak", argumentsJSON: args))],
            rawToolCalls: [.init(id: "s", name: "speak", argumentsJSON: args)])
        let gate = AsyncGate()
        let brain = GatedBrain(gate: gate, response: response)
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let box = ReviewDetailSink()
        let driver = CoachDriver(config: .default, transcript: RollingTranscript(),
            route: ConfiguredBrainRoute(targets: [.init(target: target, brain: brain)]),
            screen: ReviewScreen(succeeds: true), overlay: box, clock: ManualClock(now: 100))
        let task = Task { await driver.handleTrigger(.manualExplanation) }
        await gate.waitUntilEntered()
        box.acceptsDetail = false
        await gate.release()
        #expect(await task.value == .spoke)
        #expect(box.explanation == nil)
        box.acceptsDetail = true
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(box.explanation == "Hidden explanation.")
        let prior = try #require(brain.calls.last?.flatMap { $0.toolCalls ?? [] }.first { $0.name == "speak" })
        let object = try #require(JSONSerialization.jsonObject(with: Data(prior.argumentsJSON.utf8)) as? [String: Any])
        #expect(object["explanation"] is NSNull)
    }

    @Test func suppressedExplanationIsNotReplayedAsDelivered() async throws {
        let args = #"{"lines":["Keep this hint."],"explanation":"Hidden explanation."}"#
        let response = BrainResponse(toolCalls: [try #require(ToolInvocation.parse(
            callId: "s", name: "speak", argumentsJSON: args))],
            rawToolCalls: [.init(id: "s", name: "speak", argumentsJSON: args)])
        let brain = ScriptedBrain(script: [response])
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let driver = CoachDriver(config: .default, transcript: RollingTranscript(),
            route: ConfiguredBrainRoute(targets: [.init(target: target, brain: brain)]),
            screen: ReviewScreen(succeeds: true), overlay: FakeOverlay(), clock: ManualClock(now: 100))
        driver.updatePlan(SessionPlan(revision: 1, screen: SessionPlan.default.screen, explanationsEnabled: false))
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        let messages = try #require(brain.calls.last)
        let call = try #require(messages.flatMap { $0.toolCalls ?? [] }.first { $0.name == "speak" })
        let object = try #require(JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        #expect(object["explanation"] is NSNull)
        #expect(object["lines"] as? [String] == ["Keep this hint."])
    }
}

private struct ReviewScreen: ScreenCapturing {
    let succeeds: Bool
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
        succeeds ? ScreenSnapshot(imageBase64: "fresh-image", recognizedText: "fresh-ocr") : nil
    }
    func cancelCapture() {}
}

private final class ReviewDetailSink: OverlayRendering {
    @MainActor var acceptsDetail = true
    var explanation: String?
    func render(_ lines: [String], perLineSeconds: [TimeInterval]) {}
    func render(_ lines: [String], perLineSeconds: [TimeInterval], diagram: DiagramHint?, explanation: String?) {
        self.explanation = explanation
    }
}
