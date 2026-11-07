import Foundation
import JarvisCore
import JarvisScenarioHarness
import JarvisTestProcesses
import Testing

@Suite(.serialized)
struct EvaluationSuiteTests {
    @Test func selectedSuite() async throws {
        let environment = ProcessInfo.processInfo.environment
        let runner = EvaluationSuiteRunner(environment: environment, repository: LiveE2ELauncher.repository,
            launcher: TestCommandOwnership.makeLauncher(), screen: NeutralReplayScreen()) { layout, selected in
                let launcher = try #require(await LiveE2ELauncher.begin(scenario: layout.scenarioID,
                    file: selected.scenario, keepGoing: true))
                try await LiveE2ETests.checkScenarioA(launcher: launcher)
                return SignedAppEvaluationEvidence(directory: launcher.directory,
                    results: try String(contentsOf: launcher.directory.appendingPathComponent("results.txt"), encoding: .utf8),
                    finished: FileManager.default.fileExists(atPath: launcher.directory.appendingPathComponent("live-e2e-finished").path))
            }
        for report in try await runner.run() {
            let passed = report.passed
            #expect(passed, "Behavior baseline failed; inspect evaluation.json, no retry or label tuning")
        }
    }
}
