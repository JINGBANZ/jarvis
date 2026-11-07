import Foundation
import JarvisCore
import Testing
@testable import JarvisScenarioHarness

@Suite struct SignedAppEvaluationRunTests {
    @Test func repeatEvidencePassesProductionOutputValidationWithoutNestingReports() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let run = repository.appendingPathComponent(".jarvis/live-e2e/layout-contract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: run) }
        for index in 1...2 {
            let layout = SignedAppEvaluationRun(runDirectory: run, repeatIndex: index)
            try FileManager.default.createDirectory(at: layout.evidenceDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: layout.reportDirectory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let scenario = layout.evidenceDirectory.appendingPathComponent("scenario.json")
            try Data("{}".utf8).write(to: scenario)
            let arguments = ["--live-e2e", "--live-e2e-scenario", scenario.path,
                "--live-e2e-output-dir", layout.evidenceDirectory.path,
                "--live-e2e-repo-dir", repository.path,
                "--live-e2e-fixtures-dir", repository.appendingPathComponent("Tests/JarvisLiveTests/Fixtures").path]
            let options = try LiveE2EOptions(arguments: arguments)
            #expect(options.outputDirectory == layout.evidenceDirectory.standardizedFileURL)
            #expect(options.outputDirectory.deletingLastPathComponent() == run.standardizedFileURL)
            let nested = layout.reportDirectory.appendingPathComponent("A", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            var invalid = arguments
            invalid[try #require(invalid.firstIndex(of: "--live-e2e-output-dir")) + 1] = nested.path
            #expect(throws: LiveE2EOptions.Failure.self) { try LiveE2EOptions(arguments: invalid) }
        }
    }
}
