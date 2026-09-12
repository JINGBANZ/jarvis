import Foundation
import Testing
import JarvisCore
@testable import JarvisEvaluation
import JarvisBrainProviders

@Suite struct AgenticEvaluatorTests {
    @Test(arguments: ["development", "matching", "fallback", "unknown"])
    func evaluateRunsClaudeAndPersistsOwnerOnlyStampedReport(scenario: String) async throws {
        let isRelease = scenario != "development"
        let root = tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("session")
        let bin = root.appendingPathComponent("bin")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try await writeSessionInputs(to: session)
        let sourceRoot = root.appendingPathComponent("runs")
        let actualVersion = scenario == "matching" ? "0.2.1" : "0.2.2"
        // Release source lands in a per-run directory with an unpredictable name, so the fake CLI
        // identifies its workspace by the version its Package.swift names rather than by path.
        let marker = isRelease ? actualVersion : "dev"
        let archive = isRelease
            ? try await releaseArchive(actualVersion, in: root.appendingPathComponent("fixtures"))
            : nil
        if !isRelease {
            try Data("// fixture dev".utf8).write(to: root.appendingPathComponent("Package.swift"))
        }
        let source: EvaluationSource = isRelease
            ? .release(version: scenario == "unknown" ? nil : "0.2.1", fallbackVersion: "0.2.2")
            : .localCheckout(root)
        let provenance = isRelease ? source.releaseProvenance(using: actualVersion) : source.workspaceProvenance

        let executable = bin.appendingPathComponent("claude")
        let script = """
            #!/bin/sh
            if [ "$1" = "auth" ]; then
              printf '{"loggedIn":true}'
              exit 0
            fi
            grep -q "fixture \(marker)" Package.swift || exit 1
            case "$2" in
              *"\(provenance)"*) ;;
              *) exit 2 ;;
            esac
            printf '## Summary\\nNo issue.\\n'
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let detector = AgentCLIDetector(
            home: home,
            pathVariable: bin.path,
            authStatusTimeout: 1,
            temporaryDirectory: root.appendingPathComponent("unrelated-system-temp"))
        let evaluator = AgenticEvaluator(
            source: source,
            preferredProvider: .claudeCode,
            detector: detector,
            sourceStore: ReleaseSourceStore(root: sourceRoot) { url, destination in
                guard let archive else { Issue.record("Development source was fetched"); return }
                if scenario == "fallback" && url.lastPathComponent == "v0.2.1.tar.gz" {
                    throw URLError(.fileDoesNotExist)
                }
                #expect(url.lastPathComponent == "v\(actualVersion).tar.gz")
                try FileManager.default.copyItem(at: archive, to: destination)
            },
            timeout: 5)

        let report = try await evaluator.evaluate(sessionDirectory: session)

        if isRelease {
            // The run's source tree is discarded once evaluation returns, not left for the next one.
            #expect(try FileManager.default.contentsOfDirectory(atPath: sourceRoot.path).isEmpty)
        }

        #expect(report.contains("Produced by the agentic evaluator (`claude`"))
        #expect(report.contains("## Summary"))
        #expect(report.contains(provenance))
        #expect(AgenticEvaluation.savedReport(in: session) == report)
        let reportURL = session.appendingPathComponent(AgenticEvaluation.reportFilename)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: reportURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)
        #expect(FileManager.default.fileExists(
            atPath: session.appendingPathComponent(AgenticEvaluation.transcriptFilename).path))
    }

    @Test func preferredProviderDoesNotSilentlyFallBack() {
        let codex = DetectedAgentCLI(
            provider: .codexCLI,
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex"),
            authenticationStatus: .signedIn)
        #expect(throws: AgenticEvaluator.EvaluationError.preferredAgentUnavailable(
            BrainProvider.claudeCode.displayName
        )) {
            _ = try AgenticEvaluator.selectCLI(
                from: [codex], preferredProvider: .claudeCode)
        }
    }

    @Test func invocationsAreReadOnlyAndStateless() {
        let repository = URL(fileURLWithPath: "/repo")
        let session = URL(fileURLWithPath: "/repo/.jarvis/session")
        let claude = DetectedAgentCLI(
            provider: .claudeCode,
            executableURL: URL(fileURLWithPath: "/usr/local/bin/claude"),
            authenticationStatus: .signedIn)
        let codex = DetectedAgentCLI(
            provider: .codexCLI,
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codex"),
            authenticationStatus: .signedIn)

        let claudeRun = AgenticEvaluator.invocation(
            for: claude, prompt: "audit", repositoryDirectory: repository,
            sessionDirectory: session, timeout: 10)
        #expect(claudeRun.arguments == [
            "-p", "audit", "--no-session-persistence",
            "--setting-sources", "", "--strict-mcp-config",
            "--permission-mode", "plan",
            "--add-dir", session.path,
        ])
        #expect(claudeRun.workingDirectory == repository)

        let codexRun = AgenticEvaluator.invocation(
            for: codex, prompt: "audit", repositoryDirectory: repository,
            sessionDirectory: session, timeout: 10)
        #expect(codexRun.arguments == [
            "exec", "--ephemeral", "--sandbox", "read-only",
            "--ignore-user-config", "--ignore-rules",
            "-c", "mcp_servers={}",
            "audit",
        ])
        #expect(codexRun.workingDirectory == repository)
        let releaseRun = AgenticEvaluator.invocation(
            for: codex, prompt: "audit", repositoryDirectory: repository,
            sessionDirectory: session, timeout: 10, isReleaseSource: true)
        #expect(releaseRun.arguments == Array(codexRun.arguments.dropLast())
                + ["--skip-git-repo-check", "audit"])
    }

    private func writeSessionInputs(to session: URL) async throws {
        let traffic = await FileSessionAudit.readyForTesting(directory: session)
        traffic.record(
            tag: "coach",
            request: Data(#"{"model":"gpt-5.5","input":[]}"#.utf8),
            response: Data(#"{"status":"completed","output":[]}"#.utf8),
            status: 200,
            latencyMs: 100)
        _ = await traffic.closeForTesting()
        try Data(#"{"t":"10:00:00","m":"heard question","k":"heard"}\n"#.utf8)
            .write(to: session.appendingPathComponent(ActivityLog.filename))
    }
}
