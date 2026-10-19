import Foundation
import Testing
@testable import JarvisCore

@Suite(.serialized) struct SessionToolSetTests {
    private func makeDriver(
        brain: BrainClient,
        capabilities: CoachCapabilities = .default,
        documents: (any DocumentSession)? = nil
    ) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let target = BrainTarget(
            provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let route = ConfiguredBrainRoute(
            targets: [ConfiguredBrainTarget(target: target, brain: brain)])
        let driver = CoachDriver(
            config: .default, transcript: transcript, route: route,
            screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock(now: 100),
            automaticAttemptDelay: { _ in },
            capabilities: capabilities,
            documents: documents)
        return (driver, transcript)
    }

    private var staySilent: BrainResponse {
        .init(toolCalls: [.staySilent(callId: "s1")],
              rawToolCalls: [RawToolCall(id: "s1", name: "stay_silent", argumentsJSON: "{}")])
    }

    @Test func prepMaterialLandingMidSessionDoesNotChangeTheToolSet() async {
        let brain = ScriptedBrain(script: [staySilent, staySilent])
        let (driver, transcript) = makeDriver(
            brain: brain,
            capabilities: .compose(disabledTools: [], referencesAdmitted: true),
            documents: nil)
        transcript.append(.init(speaker: .me, text: "let me think about the ordering", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        // A session has no late-install interface; later preparation changes only outcomes.
        transcript.append(.init(speaker: .me, text: "so the map keeps the last index", at: 140))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(brain.offeredTools.count == 2)
        #expect(brain.offeredTools[0].map(\.name).contains(CoachCapabilities.loadToolName))
        #expect(brain.offeredTools[0].map(\.name) == brain.offeredTools[1].map(\.name))
        #expect(brain.offeredTools[0].map(\.parametersJSON)
            == brain.offeredTools[1].map(\.parametersJSON))
    }

    @Test func aSessionComposedWithoutReferencesNeverGainsTheTool() async {
        let brain = ScriptedBrain(script: [staySilent, staySilent])
        let (driver, transcript) = makeDriver(brain: brain, documents: nil)
        transcript.append(.init(speaker: .me, text: "let me think about the ordering", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        // A session has no late-install interface; later preparation changes only outcomes.
        transcript.append(.init(speaker: .me, text: "so the map keeps the last index", at: 140))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(brain.offeredTools.count == 2)
        #expect(!brain.offeredTools[1].map(\.name).contains(searchReferencesTool.name))
    }
}
