import Foundation
import Testing
@testable import JarvisCore

@Suite struct LiveE2EPrerequisiteTests {
    @Test func scenarioARequiresItsSwitchTargetsButNotGemini() throws {
        let scenario = try load("A")
        #expect(scenario.requiredBrainProviders == [.claudeSubscription, .openAI, .codexSubscription])
        #expect(scenario.requiredCredentials == [.openAIAPIKey])
    }

    @Test func scenarioBRequiresGeminiAndTheTranscriptionKey() throws {
        let scenario = try load("B")
        #expect(scenario.requiredBrainProviders == [.claudeSubscription, .gemini])
        #expect(scenario.requiredCredentials == [.openAIAPIKey, .geminiAPIKey])
    }

    @Test func invalidTranscriptionFixtureDoesNotRequireARealKey() throws {
        let scenario = try load("F02")
        #expect(scenario.requiredBrainProviders == [.claudeSubscription])
        #expect(scenario.requiredCredentials.isEmpty)
    }

    @Test func fallbacksAreCheckedEvenWhenNoStepSelectsThem() throws {
        let file = Self.liveTests.appendingPathComponent("Scenarios/C.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["brain"] = ["primary": "claude-subscription", "fallbacks": ["gemini", "codex-subscription"]]
        let scenario = try LiveE2EScenario.decode(
            JSONSerialization.data(withJSONObject: json), fixturesDirectory: Self.fixtures)
        #expect(scenario.requiredBrainProviders == [.claudeSubscription, .gemini, .codexSubscription])
        #expect(scenario.requiredCredentials == [.openAIAPIKey, .geminiAPIKey])
    }

    @Test func invalidTranscriptionStillRequiresTheBrainAPIKey() throws {
        let file = Self.liveTests.appendingPathComponent("Scenarios/F02.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["brain"] = ["primary": "openai", "fallbacks": []] as [String: Any]
        let scenario = try LiveE2EScenario.decode(
            JSONSerialization.data(withJSONObject: json), fixturesDirectory: Self.fixtures)
        #expect(scenario.requiredCredentials == [.openAIAPIKey])
    }

    private func load(_ id: String) throws -> LiveE2EScenario {
        try LiveE2EScenario.load(
            from: Self.liveTests.appendingPathComponent("Scenarios/\(id).json"),
            fixturesDirectory: Self.fixtures)
    }

    private static let liveTests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("JarvisLiveTests", isDirectory: true)
    private static let fixtures = liveTests.appendingPathComponent("Fixtures", isDirectory: true)
}
