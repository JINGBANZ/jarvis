import Foundation

/// Runs the sole session evaluator through a locally installed Claude Code or Codex CLI. The CLI
/// receives the repository checkout as its working directory plus the complete selected session,
/// and is constrained to a read-only, non-persisted agent run. This is Foundation-only so the app's
/// Evaluate button stays thin and the exact invocation remains unit-testable.
public struct AgenticEvaluator: Sendable {
    public enum EvaluationError: LocalizedError, Equatable {
        case noAgentCLI
        case preferredAgentUnavailable(String)
        case agentSignedOut(String)
        case agentFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noAgentCLI:
                "Install and sign in to Claude Code or Codex CLI before evaluating a session."
            case .preferredAgentUnavailable(let provider):
                "\(provider) is selected in Settings, but its CLI is not available."
            case .agentSignedOut(let provider):
                "\(provider) is signed out. Sign in, then try evaluating again."
            case .agentFailed(let provider):
                "\(provider) couldn't finish the evaluation. Check jarvis-debug.log for details."
            }
        }
    }

    private let repositoryDirectory: URL
    private let preferredProvider: BrainProvider?
    private let detector: AgentCLIDetector
    private let timeout: TimeInterval

    public init(repositoryDirectory: URL, preferredProvider: BrainProvider? = nil,
                detector: AgentCLIDetector = AgentCLIDetector(),
                timeout: TimeInterval = 15 * 60) {
        self.repositoryDirectory = repositoryDirectory
        self.preferredProvider = preferredProvider?.usesLocalCLI == true ? preferredProvider : nil
        self.detector = detector
        self.timeout = timeout
    }

    public func evaluate(sessionDirectory: URL) async throws -> String {
        let prompt = try await prepare(sessionDirectory: sessionDirectory)
        try Task.checkCancellation()
        let providers = preferredProvider.map { [$0] } ?? [.claudeCode, .codexCLI]
        let detected = await detector.detectFirstAsync(providers).map { [$0] } ?? []
        try Task.checkCancellation()
        let cli = try Self.selectCLI(from: detected, preferredProvider: preferredProvider)
        guard cli.authenticationStatus != .signedOut else {
            throw EvaluationError.agentSignedOut(cli.provider.displayName)
        }

        let invocation = Self.invocation(
            for: cli, prompt: prompt, repositoryDirectory: repositoryDirectory,
            sessionDirectory: sessionDirectory, timeout: timeout)
        let output: AgentCLIOutput
        do {
            output = try await AgentCLIProcessRunner.run(invocation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            jlog("Jarvis: \(cli.provider.displayName) evaluator process failed — \(error.localizedDescription)")
            throw EvaluationError.agentFailed(cli.provider.displayName)
        }

        guard output.exitCode == 0 else {
            let diagnostic = output.stderr.isEmpty ? output.stdout : output.stderr
            jlog("Jarvis: \(cli.provider.displayName) evaluator exited \(output.exitCode) — "
                 + String(diagnostic.suffix(2_000)))
            throw EvaluationError.agentFailed(cli.provider.displayName)
        }
        try Task.checkCancellation()
        let report = try AgenticEvaluation.saveReport(
            output.stdout, agentName: cli.executableURL.lastPathComponent, in: sessionDirectory)
        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            try? AgenticEvaluation.invalidateDerivedArtifacts(in: sessionDirectory)
            throw CancellationError()
        }
        return report
    }

    /// Traffic rendering can read a long session, so keep it off the main actor used by Activity.
    private func prepare(sessionDirectory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try AgenticEvaluation.prepare(sessionDir: sessionDirectory)
                })
            }
        }
    }

    static func selectCLI(from detected: [DetectedAgentCLI],
                          preferredProvider: BrainProvider?) throws -> DetectedAgentCLI {
        if let preferredProvider, preferredProvider.usesLocalCLI {
            guard let preferred = detected.first(where: { $0.provider == preferredProvider }) else {
                throw EvaluationError.preferredAgentUnavailable(preferredProvider.displayName)
            }
            return preferred
        }
        guard let first = detected.first else { throw EvaluationError.noAgentCLI }
        return first
    }

    static func invocation(for cli: DetectedAgentCLI, prompt: String,
                           repositoryDirectory: URL, sessionDirectory: URL,
                           timeout: TimeInterval) -> AgentCLIRun {
        let arguments: [String]
        switch cli.provider {
        case .claudeCode:
            // The prompt directly follows `-p`: `--add-dir` accepts multiple values and would
            // otherwise swallow it. Plan mode and no persistence make this a read-only, stateless
            // audit while still allowing the agent to inspect the checkout and full session.
            arguments = [
                "-p", prompt,
                "--no-session-persistence",
                "--setting-sources", "",
                "--strict-mcp-config",
                "--permission-mode", "plan",
                "--add-dir", sessionDirectory.path,
            ]
        case .codexCLI:
            arguments = [
                "exec", "--ephemeral", "--sandbox", "read-only",
                "--ignore-user-config", "--ignore-rules",
                "-c", "mcp_servers={}",
                prompt,
            ]
        case .openAI:
            preconditionFailure("Agentic evaluation requires a local agent CLI")
        }
        return AgentCLIRun(
            executable: cli.executableURL,
            arguments: arguments,
            stdin: nil,
            workingDirectory: repositoryDirectory,
            timeout: timeout)
    }
}
