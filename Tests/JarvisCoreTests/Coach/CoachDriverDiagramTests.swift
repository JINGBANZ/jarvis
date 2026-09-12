import Foundation
import Testing
@testable import JarvisCore

/// The diagram field is governed by prompt text alone — the tip style, the field's description, and
/// whichever skill the model loaded. The runtime renders any graph it can parse, whatever the
/// session turned out to be about.
@Suite struct CoachDriverDiagramTests {
    private func makeDriver(brain: BrainClient, overlay: OverlayRendering) -> CoachDriver {
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        return CoachDriver(
            config: .default, transcript: RollingTranscript(),
            route: ConfiguredBrainRoute(targets: [.init(target: target, brain: brain)]),
            screen: FakeScreen(), overlay: overlay, clock: ManualClock(now: 100))
    }

    @Test func aValidGraphReachesTheOverlay() async throws {
        let source = "flowchart LR\nA[Client] --> B[API]"
        let arguments = #"{"lines":["Sketch the request path."],"mermaid":"flowchart LR\nA[Client] --> B[API]"}"#
        let brain = ScriptedBrain(script: [.init(
            toolCalls: [try #require(ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON: arguments))],
            rawToolCalls: [.init(id: "s", name: "speak", argumentsJSON: arguments)])])
        let overlay = DiagramRecordingOverlay()
        let driver = makeDriver(brain: brain, overlay: BroadcastOverlay([overlay]))

        let outcome = await driver.handleTrigger(.manualHint)

        #expect(outcome == .spoke)
        #expect(overlay.lines == ["Sketch the request path."])
        #expect(overlay.diagram == DiagramHint(mermaid: source))
        // One speak schema on every brain and in every session: the field is always declared, and
        // the runtime decides only whether a supplied graph parses.
        let speak = try #require(brain.offeredTools.first?.first { $0.name == "speak" })
        let schema = try #require(JSONSerialization.jsonObject(with: Data(speak.parametersJSON.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["mermaid"] != nil)
        #expect(brain.toolChoices.first == .force("speak"))
    }

    /// The replayed call must describe what was actually delivered: `mermaid` is declared by the one
    /// speak schema, so it is always present, and null wherever the runtime rendered no diagram.
    @Test func replayedArgumentsCarryTheDeliveredDiagram() async throws {
        let arguments = #"{"lines":["Sketch the request path."],"mermaid":"flowchart LR\nA[Client] --> B[API]"}"#
        let response = BrainResponse(
            toolCalls: [try #require(ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON: arguments))],
            rawToolCalls: [.init(id: "s", name: "speak", argumentsJSON: arguments)])
        let brain = ScriptedBrain(script: [response, response])
        let driver = makeDriver(brain: brain, overlay: BroadcastOverlay([DiagramRecordingOverlay()]))

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(await driver.handleTrigger(.manualHint) == .spoke)

        let call = try #require(brain.calls.last?.flatMap { $0.toolCalls ?? [] }.first { $0.name == "speak" })
        let object = try #require(JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        #expect(object["lines"] as? [String] == ["Sketch the request path."])
        #expect(object["mermaid"] as? String == "flowchart LR\nA[Client] --> B[API]")
    }

    /// A graph the renderer cannot parse costs the sketch, never the tip.
    @Test func malformedDiagramStillDeliversHint() async {
        let overlay = DiagramRecordingOverlay()
        let brain = ScriptedBrain(script: [.init(toolCalls: [
            .speak(callId: "s", lines: ["Start with the API."], mermaid: "not a graph"),
        ])])
        let driver = makeDriver(brain: brain, overlay: overlay)

        #expect(await driver.handleTrigger(.manualHint) == .spoke)
        #expect(overlay.lines == ["Start with the API."])
        #expect(overlay.diagram == nil)
    }
}

// The driver awaits delivery; this sink is only read after that attempt has completed.
private final class DiagramRecordingOverlay: OverlayRendering {
    var lines: [String] = []
    var diagram: DiagramHint?
    func render(_ lines: [String], perLineSeconds: [TimeInterval]) { self.lines = lines }
    func render(_ lines: [String], perLineSeconds: [TimeInterval], diagram: DiagramHint?) {
        self.lines = lines
        self.diagram = diagram
    }
}
