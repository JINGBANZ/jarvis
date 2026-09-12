import Foundation
import Testing
@testable import JarvisCore

/// The session's coach tool set is fixed for the session's whole life.
///
/// This is not a preference: a local-agent target bakes each tool's `parametersJSON` into the
/// instructions its process is warmed with, and re-checks the composed string on every turn
/// (`CLIBrainClient.prepareTurn`). A set that grows or changes shape mid-session is rejected there,
/// failing every remaining attempt on that target. See #273.
@Suite(.serialized) struct SessionToolSetTests {
    private func makeDriver(
        brain: BrainClient,
        capabilities: CoachCapabilities = .default,
        prepMaterial: (any PrepMaterialSearching)? = nil
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
            prepMaterial: prepMaterial)
        return (driver, transcript)
    }

    private var staySilent: BrainResponse {
        .init(toolCalls: [.staySilent(callId: "s1")],
              rawToolCalls: [RawToolCall(id: "s1", name: "stay_silent", argumentsJSON: "{}")])
    }

    /// How the app actually composes a session: prep sources are configured at Start, but the index
    /// is still building, so the port lands only after the first attempts have already run. The tool
    /// set must not change when it does.
    @Test func prepMaterialLandingMidSessionDoesNotChangeTheToolSet() async {
        let brain = ScriptedBrain(script: [staySilent, staySilent])
        let (driver, transcript) = makeDriver(
            brain: brain,
            capabilities: .compose(disabledTools: [], prepSourcesConfigured: true),
            prepMaterial: nil)
        transcript.append(.init(speaker: .me, text: "let me think about the ordering", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        driver.installPrepMaterial(FakePrepMaterialSearch())
        transcript.append(.init(speaker: .me, text: "so the map keeps the last index", at: 140))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(brain.offeredTools.count == 2)
        #expect(brain.offeredTools[0].map(\.name).contains(searchPrepNotesTool.name))
        #expect(brain.offeredTools[0].map(\.name) == brain.offeredTools[1].map(\.name))
        #expect(brain.offeredTools[0].map(\.parametersJSON)
            == brain.offeredTools[1].map(\.parametersJSON))
    }

    /// The inverse of the case above: a session composed without prep material keeps the tool absent
    /// even after a port is installed, because its target was never warmed with that schema.
    @Test func aSessionComposedWithoutPrepMaterialNeverGainsTheTool() async {
        let brain = ScriptedBrain(script: [staySilent, staySilent])
        let (driver, transcript) = makeDriver(brain: brain, prepMaterial: nil)
        transcript.append(.init(speaker: .me, text: "let me think about the ordering", at: 100))

        _ = await driver.handleTrigger(.turnEnd)

        driver.installPrepMaterial(FakePrepMaterialSearch())
        transcript.append(.init(speaker: .me, text: "so the map keeps the last index", at: 140))

        _ = await driver.handleTrigger(.turnEnd)

        #expect(brain.offeredTools.count == 2)
        #expect(!brain.offeredTools[1].map(\.name).contains(searchPrepNotesTool.name))
    }
}
