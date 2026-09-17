import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachDriverDetailTests {
    private func makeDriver(brain: BrainClient, overlay: OverlayRendering,
                            detailEnabled: Bool = true) -> CoachDriver {
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        return CoachDriver(
            config: .default, transcript: RollingTranscript(),
            route: ConfiguredBrainRoute(targets: [.init(target: target, brain: brain)]),
            screen: FakeScreen(), overlay: overlay, clock: ManualClock(now: 100),
            capabilities: CoachCapabilities.compose(
                disabledTools: [], prepSourcesConfigured: false, detailEnabled: detailEnabled))
    }

    private func response(_ argumentsJSON: String) throws -> BrainResponse {
        BrainResponse(
            toolCalls: [try #require(ToolInvocation.parse(
                callId: "s", name: "speak", argumentsJSON: argumentsJSON))],
            rawToolCalls: [.init(id: "s", name: "speak", argumentsJSON: argumentsJSON)])
    }

    @Test func aMermaidBlockInDetailReachesTheDetailBox() async throws {
        let arguments = #"{"lines":["Sketch the request path."],"detail":"A first sketch.\n\n```mermaid\nflowchart LR\nA[Client] --> B[API]\n```"}"#
        let brain = ScriptedBrain(script: [try response(arguments)])
        let overlay = DetailRecordingOverlay()
        let driver = makeDriver(brain: brain, overlay: BroadcastOverlay([overlay]))

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(overlay.lines == ["Sketch the request path."])
        #expect(overlay.detail?.diagram == DiagramHint(mermaid: "flowchart LR\nA[Client] --> B[API]"))
        #expect(overlay.detail?.dropped.isEmpty == true)

        let speak = try #require(brain.offeredTools.first?.first { $0.name == "speak" })
        let schema = try #require(JSONSerialization.jsonObject(
            with: Data(speak.parametersJSON.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties.keys.sorted() == ["detail", "lines"])
        #expect(brain.toolChoices.first == .force("speak"))
    }

    @Test func replayedArgumentsCarryTheDeliveredDetail() async throws {
        let arguments = #"{"lines":["Sketch the request path."],"detail":"A first sketch.\n\n```mermaid\nflowchart LR\nA[Client] --> B[API]\n```"}"#
        let brain = ScriptedBrain(script: [try response(arguments), try response(arguments)])
        let driver = makeDriver(brain: brain, overlay: BroadcastOverlay([DetailRecordingOverlay()]))

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        let call = try #require(brain.calls.last?.flatMap { $0.toolCalls ?? [] }
            .first { $0.name == "speak" })
        let object = try #require(JSONSerialization.jsonObject(
            with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        #expect(object["lines"] as? [String] == ["Sketch the request path."])
        #expect((object["detail"] as? String)?.contains("```mermaid") == true)
    }

    @Test func aDroppedBlockLeavesTheReplayAndIsReportedToTheModel() async throws {
        let arguments = #"{"lines":["Start with the API."],"detail":"Use a queue.\n\n```mermaid\nsequenceDiagram\nA->>B: write\n```"}"#
        let brain = ScriptedBrain(script: [try response(arguments), try response(arguments)])
        let overlay = DetailRecordingOverlay()
        let driver = makeDriver(brain: brain, overlay: BroadcastOverlay([overlay]))

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        #expect(overlay.lines == ["Start with the API."])
        #expect(overlay.detail?.diagram == nil)
        let last = try #require(brain.calls.last)
        let call = try #require(last.flatMap { $0.toolCalls ?? [] }.first { $0.name == "speak" })
        let object = try #require(JSONSerialization.jsonObject(
            with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        #expect((object["detail"] as? String)?.contains("sequenceDiagram") == false)
        let result = try #require(last.first { $0.role == .tool && $0.toolCallId == call.id })
        #expect(result.text?.contains("not a supported graph") == true)
    }

    @Test func aMalformedDiagramStillDeliversTheHint() async throws {
        let arguments = #"{"lines":["Start with the API."],"detail":"```mermaid\nnot a graph\n```"}"#
        let brain = ScriptedBrain(script: [try response(arguments)])
        let overlay = DetailRecordingOverlay()
        let driver = makeDriver(brain: brain, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(overlay.lines == ["Start with the API."])
        #expect(overlay.detail?.hasContent != true)
    }

    @Test func aSessionWithoutTheBoxNeitherDeclaresNorDeliversDetail() async throws {
        let arguments = #"{"lines":["Start with the API."],"detail":"Hidden."}"#
        let brain = ScriptedBrain(script: [try response(arguments), try response(arguments)])
        let overlay = DetailRecordingOverlay()
        let driver = makeDriver(brain: brain, overlay: overlay, detailEnabled: false)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(overlay.detail == nil)

        let speak = try #require(brain.offeredTools.first?.first { $0.name == "speak" })
        #expect(!speak.parametersJSON.contains("detail"))
        let call = try #require(brain.calls.last?.flatMap { $0.toolCalls ?? [] }
            .first { $0.name == "speak" })
        let object = try #require(JSONSerialization.jsonObject(
            with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        #expect(object["detail"] == nil)
    }
}

// The driver awaits delivery; this sink is only read after that attempt has completed.
private final class DetailRecordingOverlay: OverlayRendering, @unchecked Sendable {
    @MainActor var acceptsDetail: Bool { true }
    var lines: [String] = []
    var detail: ReplyDetail?
    func render(_ lines: [String], perLineSeconds: [TimeInterval]) { self.lines = lines }
    func render(_ lines: [String], perLineSeconds: [TimeInterval], detail: ReplyDetail?) {
        self.lines = lines
        self.detail = detail
    }
}
