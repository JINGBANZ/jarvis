import Foundation
import Testing
@testable import JarvisCore

@Suite struct LiveE2EProviderTests {
    private static let liveTests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("JarvisLiveTests", isDirectory: true)
    private static let fixtures = liveTests.appendingPathComponent("Fixtures", isDirectory: true)

    @Test(arguments: ["A", "B", "C", "D", "H", "P", "R", "F01-system", "F01-microphone", "F02"],
          BrainProvider.allCases)
    func providerSelectionSurvivesSerialization(id: String, provider: BrainProvider) throws {
        let source = try data(id)
        let original = try decode(source)
        let selected = try decode(LiveE2EScenario.selectingProvider(
            provider, in: source, fixturesDirectory: Self.fixtures))

        #expect(selected.brain == .init(primary: provider, fallbacks: []))
        #expect(selected.requiredBrainProviders == [provider])
        #expect(selected.steps == original.steps.filter {
            if case .switchBrain = $0 { false } else { true }
        })
        #expect(selected.id == original.id)
        #expect(selected.audio == original.audio)
        #expect(selected.capabilities == original.capabilities)
        #expect(selected.prepNotes == original.prepNotes)
        #expect(selected.historyCompactionTokenThreshold == original.historyCompactionTokenThreshold)
        #expect(selected.transcription == original.transcription)
        #expect(selected.voices == original.voices)
        var credentials = Set([provider.credential].compactMap { $0 })
        if selected.transcription.key == .standard { credentials.insert(.openAIAPIKey) }
        #expect(selected.requiredCredentials == credentials)
    }

    @Test func codexSelectionRemovesFallbackCredentials() throws {
        var json = try #require(JSONSerialization.jsonObject(with: data("C")) as? [String: Any])
        json["brain"] = ["primary": "claude-subscription", "fallbacks": ["gemini", "openai"]]
        let selected = try decode(LiveE2EScenario.selectingProvider(
            .codexSubscription, in: JSONSerialization.data(withJSONObject: json),
            fixturesDirectory: Self.fixtures))
        #expect(selected.requiredBrainProviders == [.codexSubscription])
        #expect(selected.requiredCredentials == [.openAIAPIKey])
    }

    @Test(arguments: TranscriptionTarget.remoteTargets, BrainProvider.allCases)
    func coachingSelectionPreservesBilingualTranscription(
        target: TranscriptionTarget, provider: BrainProvider
    ) throws {
        var json = try #require(JSONSerialization.jsonObject(with: data("L")) as? [String: Any])
        var transcription = try #require(json["transcription"] as? [String: Any])
        transcription["provider"] = target.provider.rawValue
        transcription["model"] = target.modelID
        json["transcription"] = transcription
        let selected = try decode(LiveE2EScenario.selectingProvider(
            provider, in: JSONSerialization.data(withJSONObject: json),
            fixturesDirectory: Self.fixtures))

        #expect(selected.brain == .init(primary: provider, fallbacks: []))
        #expect(selected.transcription.target == target)
        #expect(selected.transcription.expectedLanguages == [.english, .mandarinChinese])
        let credentials = Set([provider.credential, target.provider.ownCredential].compactMap { $0 })
        #expect(selected.requiredCredentials == credentials)
    }

    @Test func overrideDoesNotHideAnInvalidSwitch() throws {
        var json = try #require(JSONSerialization.jsonObject(with: data("B")) as? [String: Any])
        json["steps"] = [["switchBrain": "unknown"], ["stop": true]] as [[String: Any]]
        let invalid = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: LiveE2EScenario.Failure.self) {
            try LiveE2EScenario.selectingProvider(
                .codexSubscription, in: invalid, fixturesDirectory: Self.fixtures)
        }
    }

    @Test("ordinary scenarios retain explicit models until a provider override")
    func explicitModelSelection() throws {
        var json = try #require(JSONSerialization.jsonObject(with: data("C")) as? [String: Any])
        let provider = BrainProvider.codexSubscription
        let defaultTarget = LiveE2EScenario.target(for: provider)
        let alternate = try #require(BrainModelCatalog.models(for: provider).first { $0.id != defaultTarget.modelID })
        json["brain"] = ["primary": provider.rawValue, "model": alternate.id, "fallbacks": []] as [String: Any]
        let source = try JSONSerialization.data(withJSONObject: json)
        let scenario = try decode(source)
        #expect(LiveE2EScenario.target(for: scenario.brain.primary, modelID: scenario.brain.model)
            == BrainTarget(provider: provider, modelID: alternate.id))
        let selected = try decode(LiveE2EScenario.selectingProvider(provider, in: source, fixturesDirectory: Self.fixtures))
        #expect(LiveE2EScenario.target(for: selected.brain.primary, modelID: selected.brain.model) == defaultTarget)
    }

    @Test func scenarioModeKeepsSwitchProvidersAtTheirSteps() throws {
        let scenario = try decode(data("A"))
        #expect(scenario.requiredBrainProviders == [.claudeSubscription, .openAI, .codexSubscription])
        var current = scenario.brain.primary
        for (index, step) in scenario.steps.enumerated() {
            #expect(scenario.provider(atStep: index) == current)
            if case .switchBrain(let provider) = step { current = provider }
        }
    }

    private func data(_ id: String) throws -> Data {
        try Data(contentsOf: Self.liveTests.appendingPathComponent("Scenarios/\(id).json"))
    }

    private func decode(_ data: Data) throws -> LiveE2EScenario {
        try LiveE2EScenario.decode(data, fixturesDirectory: Self.fixtures)
    }
}
