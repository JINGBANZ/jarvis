import Foundation
import Testing
@testable import JarvisCore

@Suite("Live e2e options")
struct LiveE2EOptionsTests {
    private struct Layout {
        let root: URL

        var repository: URL { root.appendingPathComponent("repo", isDirectory: true) }
        var base: URL { repository.appendingPathComponent(".jarvis/live-e2e", isDirectory: true) }
        var output: URL { base.appendingPathComponent("run-1/A", isDirectory: true) }
        var scenario: URL { root.appendingPathComponent("A.json") }
        var fixtures: URL { root.appendingPathComponent("fixtures", isDirectory: true) }
        var outside: URL { root.appendingPathComponent("outside", isDirectory: true) }

        static func make() throws -> Layout {
            let layout = Layout(root: ActivityLogTests.tmp())
            let files = FileManager.default
            try files.createDirectory(at: layout.output, withIntermediateDirectories: true)
            try files.createDirectory(at: layout.fixtures, withIntermediateDirectories: true)
            try files.createDirectory(at: layout.outside, withIntermediateDirectories: true)
            try Data("// test package".utf8).write(
                to: layout.repository.appendingPathComponent("Package.swift"))
            try Data("{}".utf8).write(to: layout.scenario)
            return layout
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func arguments(
            output: URL? = nil,
            scenario: URL? = nil,
            fixtures: URL? = nil,
            secrets: URL? = nil,
            omitting omitted: String? = nil
        ) -> [String] {
            var pairs: [(String, String)] = [
                ("--live-e2e-scenario", (scenario ?? self.scenario).path),
                ("--live-e2e-output-dir", (output ?? self.output).path),
                ("--live-e2e-repo-dir", repository.path),
                ("--live-e2e-fixtures-dir", (fixtures ?? self.fixtures).path),
            ]
            if let secrets { pairs.append(("--live-e2e-secrets-dir", secrets.path)) }
            return ["JarvisApp", "--live-e2e"]
                + pairs.filter { $0.0 != omitted }.flatMap { [$0.0, $0.1] }
        }
    }

    @Test("every flag is parsed into a standardized URL")
    func parsesEveryFlag() throws {
        let layout = try Layout.make()
        defer { layout.remove() }
        let secrets = layout.root.appendingPathComponent("secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)

        let options = try LiveE2EOptions(
            arguments: layout.arguments(secrets: secrets))

        #expect(options.scenarioURL.path == layout.scenario.standardizedFileURL.path)
        #expect(options.outputDirectory.path == resolved(layout.output).path)
        #expect(options.repositoryDirectory.path == resolved(layout.repository).path)
        #expect(options.fixturesDirectory.path == layout.fixtures.standardizedFileURL.path)
        #expect(options.secretsDirectory?.path == secrets.standardizedFileURL.path)
    }

    @Test("browser capture uses its own confined output base")
    func browserCaptureUsesSeparateBase() throws {
        let layout = try Layout.make()
        defer { layout.remove() }
        let output = layout.repository.appendingPathComponent(".jarvis/browser-capture/chrome-1/Chrome")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: output.appendingPathComponent("scenario.json"))

        let options = try LiveE2EOptions(
            arguments: layout.arguments(output: output) + ["--browser-capture-check"])
        #expect(options.outputDirectory.path == resolved(output).path)
        #expect(invalidDetail(failure(layout.arguments(output: output)))?.contains("exactly two levels") == true)
        #expect(invalidDetail(failure(layout.arguments() + ["--browser-capture-check"]))?
            .contains("exactly two levels") == true)
    }

    @Test(arguments: [".jarvis/browser-capture/chrome-1",
                      ".jarvis/browser-capture/chrome-1/Chrome/extra",
                      ".jarvis/browser-capture-escape/chrome-1/Chrome"])
    func browserCaptureRejectsWrongBaseOrDepth(relativeOutput: String) throws {
        let layout = try Layout.make()
        defer { layout.remove() }
        let output = layout.repository.appendingPathComponent(relativeOutput)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let result = failure(layout.arguments(output: output) + ["--browser-capture-check"])
        #expect(invalidDetail(result)?.contains("exactly two levels") == true)
    }

    @Test("browser capture retains symlink and stale-output protections")
    func browserCaptureRejectsRedirectedOrStaleOutput() throws {
        let layout = try Layout.make()
        defer { layout.remove() }
        let base = layout.repository.appendingPathComponent(".jarvis/browser-capture")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("linked-run")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: layout.outside)
        let redirected = failure(layout.arguments(output: link.appendingPathComponent("Chrome"))
            + ["--browser-capture-check"])
        #expect(invalidDetail(redirected)?.contains("symbolic links") == true)

        let output = base.appendingPathComponent("chrome-1/Chrome")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("CHROME pass".utf8).write(to: output.appendingPathComponent("capture-check.txt"))
        let stale = failure(layout.arguments(output: output) + ["--browser-capture-check"])
        #expect(invalidDetail(stale)?.contains("empty except for scenario.json") == true)
    }

    @Test("the optional flags default to nil")
    func optionalFlagsDefaultToNil() throws {
        let layout = try Layout.make()
        defer { layout.remove() }

        let options = try LiveE2EOptions(arguments: layout.arguments())

        #expect(options.secretsDirectory == nil)
    }

    @Test(
        "each required flag is reported when missing",
        arguments: [
            "--live-e2e-scenario", "--live-e2e-output-dir", "--live-e2e-repo-dir",
            "--live-e2e-fixtures-dir",
        ])
    func reportsMissingFlag(flag: String) throws {
        let layout = try Layout.make()
        defer { layout.remove() }

        let failure = failure(layout.arguments(omitting: flag))

        #expect(missingName(failure) == flag)
    }

    @Test("a flag at the end of the arguments has no value and is reported missing")
    func reportsTrailingFlagWithoutValue() throws {
        let layout = try Layout.make()
        defer { layout.remove() }

        let failure = failure(
            layout.arguments(omitting: "--live-e2e-fixtures-dir") + ["--live-e2e-fixtures-dir"])

        #expect(missingName(failure) == "--live-e2e-fixtures-dir")
    }

    @Test("the scenario must be an existing file")
    func rejectsMissingOrDirectoryScenario() throws {
        let layout = try Layout.make()
        defer { layout.remove() }

        let absent = failure(layout.arguments(
            scenario: layout.root.appendingPathComponent("absent.json")))
        let directory = failure(layout.arguments(scenario: layout.fixtures))

        #expect(invalidDetail(absent)?.contains("--live-e2e-scenario") == true)
        #expect(invalidDetail(directory)?.contains("--live-e2e-scenario") == true)
    }

    @Test("the fixtures directory must exist")
    func rejectsMissingFixtures() throws {
        let layout = try Layout.make()
        defer { layout.remove() }

        let absent = failure(layout.arguments(
            fixtures: layout.root.appendingPathComponent("absent", isDirectory: true)))
        let file = failure(layout.arguments(fixtures: layout.scenario))

        #expect(invalidDetail(absent)?.contains("--live-e2e-fixtures-dir") == true)
        #expect(invalidDetail(file)?.contains("--live-e2e-fixtures-dir") == true)
    }

    @Test("a given secrets directory must exist")
    func rejectsMissingSecrets() throws {
        let layout = try Layout.make()
        defer { layout.remove() }

        let failure = failure(layout.arguments(
            secrets: layout.root.appendingPathComponent("absent", isDirectory: true)))

        #expect(invalidDetail(failure)?.contains("--live-e2e-secrets-dir") == true)
    }

    @Test(
        "output must sit exactly two levels below the live e2e base",
        arguments: ["run-1", "run-1/A/extra"])
    func rejectsWrongDepth(relativeOutput: String) throws {
        let layout = try Layout.make()
        defer { layout.remove() }
        let output = layout.base.appendingPathComponent(relativeOutput, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let failure = failure(layout.arguments(output: output))

        #expect(invalidDetail(failure)?.contains("exactly two levels") == true)
    }

    @Test("a similarly prefixed sibling of the live e2e base is rejected")
    func rejectsSiblingBase() throws {
        let layout = try Layout.make()
        defer { layout.remove() }
        let output = layout.repository.appendingPathComponent(
            ".jarvis/live-e2e-escape/run-1/A", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let failure = failure(layout.arguments(output: output))

        #expect(invalidDetail(failure)?.contains("exactly two levels") == true)
    }

    @Test("output outside the repository is rejected")
    func rejectsOutputOutsideRepository() throws {
        let layout = try Layout.make()
        defer { layout.remove() }

        let failure = failure(layout.arguments(output: layout.outside))

        #expect(invalidDetail(failure)?.contains("inside the repository") == true)
    }

    @Test("a symlinked component cannot redirect the output")
    func rejectsSymlinkedComponent() throws {
        let layout = try Layout.make()
        defer { layout.remove() }
        let redirected = layout.outside.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
        let link = layout.base.appendingPathComponent("linked-run", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: layout.outside)

        let failure = failure(layout.arguments(
            output: link.appendingPathComponent("A", isDirectory: true)))

        #expect(invalidDetail(failure)?.contains("symbolic links") == true)
    }

    @Test("the output directory must exist")
    func rejectsMissingOutput() throws {
        let layout = try Layout.make()
        defer { layout.remove() }

        let failure = failure(layout.arguments(
            output: layout.base.appendingPathComponent("run-1/B", isDirectory: true)))

        #expect(invalidDetail(failure)?.contains("does not exist") == true)
    }

    @Test("the output directory may hold only scenario.json")
    func requiresEmptyOutputExceptScenario() throws {
        let layout = try Layout.make()
        defer { layout.remove() }

        try Data("{}".utf8).write(to: layout.output.appendingPathComponent("scenario.json"))
        #expect(throws: Never.self) { try LiveE2EOptions(arguments: layout.arguments()) }

        try Data("old".utf8).write(to: layout.output.appendingPathComponent("results.txt"))
        let failure = failure(layout.arguments())
        #expect(invalidDetail(failure)?.contains("empty except for scenario.json") == true)
    }

    @Test("the repository must contain Package.swift")
    func rejectsRepositoryWithoutPackage() throws {
        let layout = try Layout.make()
        defer { layout.remove() }
        try FileManager.default.removeItem(
            at: layout.repository.appendingPathComponent("Package.swift"))

        let failure = failure(layout.arguments())

        #expect(invalidDetail(failure)?.contains("Package.swift") == true)
    }

    @Test("only the exact --live-e2e argument requests the mode")
    func isRequestedMatchesTheExactFlag() {
        #expect(LiveE2EOptions.isRequested(in: ["JarvisApp", "--live-e2e"]))
        #expect(LiveE2EOptions.isRequested(in: ["JarvisApp", "--live-e2e-scenario", "A.json", "--live-e2e"]))
        #expect(!LiveE2EOptions.isRequested(in: ["JarvisApp"]))
        #expect(!LiveE2EOptions.isRequested(in: ["JarvisApp", "--live-e2e-scenario", "A.json"]))
        #expect(!LiveE2EOptions.isRequested(in: ["JarvisApp", "--transcription-benchmark"]))
    }

    private func resolved(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func failure(_ arguments: [String]) -> LiveE2EOptions.Failure? {
        do {
            _ = try LiveE2EOptions(arguments: arguments)
            return nil
        } catch let failure as LiveE2EOptions.Failure {
            return failure
        } catch {
            Issue.record("Unexpected error: \(error)")
            return nil
        }
    }

    private func missingName(_ failure: LiveE2EOptions.Failure?) -> String? {
        guard case .missing(let name) = failure else { return nil }
        return name
    }

    private func invalidDetail(_ failure: LiveE2EOptions.Failure?) -> String? {
        guard case .invalid(let detail) = failure else { return nil }
        return detail
    }
}
