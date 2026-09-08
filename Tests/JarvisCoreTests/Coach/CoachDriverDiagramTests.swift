import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachDriverDiagramTests {
    @Test(arguments: [InterviewFormat.systemDesign, .coding, .behavioral, nil])
    func graphOnlyReachesOverlayInSystemDesign(_ format: InterviewFormat?) async throws {
        let source = "flowchart LR\nA[Client] --> B[API]"
        let arguments = #"{"lines":["Sketch the request path."],"mermaid":"flowchart LR\nA[Client] --> B[API]"}"#
        let brain = ScriptedBrain(script: [.init(
            toolCalls: [try #require(ToolInvocation.parse(callId: "s", name: "speak", argumentsJSON: arguments))],
            rawToolCalls: [.init(id: "s", name: "speak", argumentsJSON: arguments)])])
        let overlay = DiagramRecordingOverlay()
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let driver = CoachDriver(
            config: .default, transcript: RollingTranscript(),
            route: ConfiguredBrainRoute(targets: [.init(target: target, brain: brain)]),
            screen: FakeScreen(), overlay: BroadcastOverlay([overlay]), clock: ManualClock(now: 100),
            interviewFormatAddendum: format?.promptAddendum ?? "", interviewFormat: format)

        let outcome = await driver.handleTrigger(.manualHint)

        #expect(outcome == .spoke)
        #expect(overlay.lines == ["Sketch the request path."])
        #expect(overlay.diagram == (format == .systemDesign ? DiagramHint(mermaid: source) : nil))
        let speak = try #require(brain.offeredTools.first?.first { $0.name == "speak" })
        let schema = try #require(JSONSerialization.jsonObject(with: Data(speak.parametersJSON.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect((properties["mermaid"] != nil) == (format == .systemDesign))
        #expect(brain.toolChoices.first == .force("speak"))
    }

    @Test func malformedDiagramStillDeliversHint() async {
        let overlay = DiagramRecordingOverlay()
        let brain = ScriptedBrain(script: [.init(toolCalls: [
            .speak(callId: "s", lines: ["Start with the API."], mermaid: "not a graph"),
        ])])
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let driver = CoachDriver(
            config: .default, transcript: RollingTranscript(),
            route: ConfiguredBrainRoute(targets: [.init(target: target, brain: brain)]),
            screen: FakeScreen(), overlay: overlay, clock: ManualClock(now: 100),
            interviewFormat: .systemDesign)
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
