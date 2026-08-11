import Foundation
import Testing
@testable import JarvisCore

@Suite struct AgenticEvaluatorTests {
    @Test func evaluateRunsClaudeAndPersistsOwnerOnlyStampedReport() async throws {
        let root = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("session")
        let bin = root.appendingPathComponent("bin")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try await writeSessionInputs(to: session)

        let executable = bin.appendingPathComponent("claude")
        let script = """
            #!/bin/sh
            if [ "$1" = "auth" ]; then
              printf '{"loggedIn":true}'
              exit 0
            fi
            printf '## Context engineering\\nNo issue.\\n'
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
            repositoryDirectory: root,
            preferredProvider: .claudeCode,
            detector: detector,
            timeout: 5)

        let report = try await evaluator.evaluate(sessionDirectory: session)

        #expect(report.contains("Produced by the agentic evaluator (`claude`"))
        #expect(report.contains("## Context engineering"))
        #expect(AgenticEvaluation.savedReport(in: session) == report)
        let reportURL = session.appendingPathComponent(AgenticEvaluation.reportFilename)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: reportURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)
        let evidencePermissions = try FileManager.default.attributesOfItem(
            atPath: session.appendingPathComponent(
                AgenticEvaluation.reportEvidenceFilename).path)[.posixPermissions] as? NSNumber
        #expect(evidencePermissions?.int16Value == 0o600)
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

    @Test func evidenceChangingDuringAgentRunDiscardsItsReport() async throws {
        let root = ActivityLogTests.tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("session")
        let bin = root.appendingPathComponent("bin")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try await writeSessionInputs(to: session)

        let started = root.appendingPathComponent("evaluation-started")
        let release = root.appendingPathComponent("release-evaluation")
        let executable = bin.appendingPathComponent("claude")
        let script = """
            #!/bin/sh
            if [ "$1" = "auth" ]; then
              printf '{"loggedIn":true}'
              exit 0
            fi
            : > '\(started.path)'
            while [ ! -f '\(release.path)' ]; do sleep 0.01; done
            printf '## Stale result\\n'
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
            repositoryDirectory: root,
            preferredProvider: .claudeCode,
            detector: detector,
            timeout: 5)

        let evaluation = Task {
            try await evaluator.evaluate(sessionDirectory: session)
        }
        while !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try Data(#"{"version":1,"state":"partial","late_event":1}"#.utf8).write(
            to: session.appendingPathComponent(FileSessionAudit.healthFilename))
        try Data().write(to: release)

        await #expect(throws: AgenticEvaluation.EvaluationError.evidenceChanged) {
            try await evaluation.value
        }
        #expect(AgenticEvaluation.savedReport(in: session) == nil)
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
