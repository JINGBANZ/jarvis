import Testing
@testable import JarvisCore

@Suite struct CoachAdmissionSnapshotTests {
    @Test @MainActor func targetSelectionCannotExpandTheAdmittedTranscript() async throws {
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .me, text: "First complete question.", at: 1))
        let brain = ScriptedBrain(script: [.init(toolCalls: [.staySilent(callId: "quiet")])])
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        var selectedDriver: CoachDriver?
        let driver = CoachDriver(
            config: .default, transcript: transcript,
            route: ConfiguredBrainRoute(
                targets: [.init(target: target, brain: brain)],
                onSelected: { _ in
                    selectedDriver?.updateTranscriptionWork(.pending(since: 2), for: .them)
                    transcript.append(.init(speaker: .me, text: "Later unadmitted reply.", at: 3))
                }),
            screen: FakeScreen(), overlay: FakeOverlay(), clock: ManualClock())

        selectedDriver = driver
        #expect(await driver.handleTrigger(.turnEnd, transcriptBoundary: 1) == .silentByModel)
        let request = try #require(brain.calls.first)
        let text = request.compactMap(\.text).joined(separator: "\n")
        #expect(text.contains("First complete question."))
        #expect(!text.contains("Later unadmitted reply."))
    }
}
