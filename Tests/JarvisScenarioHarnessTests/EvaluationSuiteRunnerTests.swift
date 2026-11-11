import Foundation
import JarvisCore
import JarvisProcess
@testable import JarvisScenarioHarness
import Testing

@Suite struct EvaluationSuiteRunnerTests {
    @Test func identicalCoachAndJudgeModelsProduceAnActionableRunError() async throws {
        let directory = tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let config = TestProviderConfiguration.shared
        let runner = EvaluationSuiteRunner(environment: [
            "JARVIS_EVALUATION_SUITE": "coaching/intervention", "JARVIS_EVALUATION_REPEAT": "1",
            "JARVIS_LIVE_E2E_PROVIDER": config.defaultJudgeProvider.rawValue,
            "JARVIS_EVALUATION_MODEL": config.modelID(for: config.defaultJudgeProvider, judge: true),
            "JARVIS_LIVE_E2E_RUN_DIR": directory.path,
        ], repository: repository, launcher: UnusedScenarioLauncher(), screen: UnusedScenarioScreen()) { _, _ in
            throw EvaluationSuiteRunner.Failure.invalidConfiguration
        }
        await #expect(throws: EvaluationSuiteRunner.Failure.self) { try await runner.run() }
        let report = try JSONDecoder().decode(EvaluationSuiteReport.self,
            from: Data(contentsOf: directory.appendingPathComponent("evaluation.json")))
        #expect(!report.passed)
        #expect(report.runErrors.first?.contains("different model IDs") == true)
        #expect(report.runErrors.first?.contains("JARVIS_EVALUATION_JUDGE_MODEL") == true)
    }

    @Test func signedAppRepeatsPreserveFailuresAndEmptyEvidence() async throws {
        let directory = tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let runner = EvaluationSuiteRunner(environment: [
            "JARVIS_EVALUATION_SUITE": "app/coaching", "JARVIS_EVALUATION_REPEAT": "2",
            "JARVIS_LIVE_E2E_PROVIDER": BrainProvider.openAI.rawValue,
            "JARVIS_LIVE_E2E_RUN_DIR": directory.path,
        ], repository: repository, launcher: UnusedScenarioLauncher(), screen: UnusedScenarioScreen()) { layout, selected in
            #expect(selected.scenario == "A")
            return SignedAppEvaluationEvidence(directory: layout.evidenceDirectory,
                results: layout.scenarioID == "A-repeat-1" ? "assertion fail synthetic" : "", finished: true)
        }
        let reports = try await runner.run()
        #expect(reports.count == 2)
        #expect(reports.allSatisfy { !$0.passed })
        #expect(reports[0].results.first?.status == .fail)
        #expect(reports[1].results.isEmpty)
        for index in 1...2 {
            let report = try JSONDecoder().decode(EvaluationSuiteReport.self,
                from: Data(contentsOf: directory.appendingPathComponent("repeat-\(index)/evaluation.json")))
            #expect(!report.passed)
        }
    }

    @Test func invalidSelectionWritesExecutionError() async throws {
        let directory = tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = EvaluationSuiteRunner(environment: ["JARVIS_LIVE_E2E_RUN_DIR": directory.path],
            repository: directory, launcher: UnusedScenarioLauncher(), screen: UnusedScenarioScreen()) { _, _ in
                throw EvaluationSuiteRunner.Failure.invalidConfiguration
            }
        await #expect(throws: EvaluationSuiteRunner.Failure.self) { try await runner.run() }
        let report = try JSONDecoder().decode(EvaluationSuiteReport.self,
            from: Data(contentsOf: directory.appendingPathComponent("evaluation.json")))
        #expect(!report.passed)
        #expect(report.runErrors.count == 1)
    }
}

private struct UnusedScenarioLauncher: ProcessLaunching {
    func launch(_ process: Process, onLaunch: () -> Void) throws {
        throw EvaluationSuiteRunner.Failure.invalidConfiguration
    }
}

private struct UnusedScenarioScreen: ScreenCapturing {
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? { nil }
    func makeAttemptCapture() -> any ScreenCapturing { self }
    func cancelCapture() {}
}
