import Foundation
import JarvisCore
import JarvisBrainProviders

/// The agent CLI run must stay read-only and non-persisted.
public struct AgenticEvaluator: Sendable {
    public enum EvaluationError: LocalizedError, Equatable {
        case noAgentCLI
        case preferredAgentUnavailable(String)
        case agentSignedOut(String)
        /// `reason` is already redacted.
        case agentFailed(cli: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .noAgentCLI:
                "Install and sign in to Codex or Claude Code before evaluating a session."
            case .preferredAgentUnavailable(let cli):
                "\(cli) was requested, but its CLI is not installed."
            case .agentSignedOut(let cli):
                "\(cli) is signed out. Sign in, then try evaluating again."
            case .agentFailed(let cli, let reason):
                "\(cli) couldn't finish the evaluation: \(reason)"
            }
        }
    }

    public static let searchOrder: [AgentCLI] = [.codex, .claude]

    private let source: EvaluationSource
    private let sourceStore: ReleaseSourceStore
    private let preferredCLI: AgentCLI?
    private let detector: AgentCLIDetector
    private let timeout: TimeInterval

    public init(source: EvaluationSource, preferredCLI: AgentCLI? = nil,
                detector: AgentCLIDetector = AgentCLIDetector(),
                sourceStore: ReleaseSourceStore = ReleaseSourceStore(),
                timeout: TimeInterval = 15 * 60) {
        self.source = source
        self.sourceStore = sourceStore
        self.preferredCLI = preferredCLI
        self.detector = detector
        self.timeout = timeout
    }

    public func evaluate(sessionDirectory: URL,
                         onFetchingSource: @MainActor @Sendable (Bool) -> Void = { _ in }) async throws -> String {
        let repositoryDirectory: URL
        let isRelease: Bool
        let provenance: String
        // Function-scoped so the discard outlives the CLI invocation below.
        var fetched: ReleaseSourceStore.Checkout?
        defer { fetched?.discard() }
        switch source {
        case .localCheckout(let directory):
            repositoryDirectory = directory
            isRelease = false
            provenance = source.workspaceProvenance
        case .release(let version, let fallbackVersion):
            await onFetchingSource(true)
            let checkout = try await sourceStore.fetch(version: version,
                                                       fallbackVersion: fallbackVersion)
            fetched = checkout
            repositoryDirectory = checkout.directory
            provenance = source.releaseProvenance(using: checkout.version)
            await onFetchingSource(false)
            isRelease = true
        }
        let prompt = try await prepare(sessionDirectory: sessionDirectory, workspaceProvenance: provenance)
        try Task.checkCancellation()
        let detected = await detector.detectAllAsync(preferredCLI.map { [$0] } ?? Self.searchOrder)
        try Task.checkCancellation()
        let cli = try Self.selectCLI(from: detected, preferredCLI: preferredCLI)

        let invocation = Self.invocation(
            for: cli, prompt: prompt, repositoryDirectory: repositoryDirectory,
            sessionDirectory: sessionDirectory, timeout: timeout, isReleaseSource: isRelease)
        let output: AgentCLIOutput
        do {
            output = try await AgentCLIProcessRunner.run(invocation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            jlog("Jarvis: \(cli.cli.displayName) evaluator process failed — \(error.localizedDescription)")
            throw EvaluationError.agentFailed(
                cli: cli.cli.displayName,
                reason: ProviderMessageRedaction.redact(error.localizedDescription))
        }

        guard output.exitCode == 0 else {
            let diagnostic = output.stderr.isEmpty ? output.stdout : output.stderr
            jlog("Jarvis: \(cli.cli.displayName) evaluator exited \(output.exitCode) — "
                 + String(diagnostic.suffix(2_000)))
            throw EvaluationError.agentFailed(
                cli: cli.cli.displayName, reason: Self.failureReason(output))
        }
        try Task.checkCancellation()
        return try AgenticEvaluation.saveReport(
            output.stdout, agentName: cli.executableURL.lastPathComponent, in: sessionDirectory,
            workspaceProvenance: provenance)
    }

    /// Rendering a long session is slow, so keep it off the main actor that Activity uses.
    private func prepare(sessionDirectory: URL, workspaceProvenance: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try AgenticEvaluation.prepare(sessionDir: sessionDirectory,
                                                  workspaceProvenance: workspaceProvenance)
                })
            }
        }
    }

    /// Claude Code prints a failed run's error last on stdout, with warnings on stderr; Codex prints
    /// it last on stderr and nothing on stdout.
    static func failureReason(_ output: AgentCLIOutput) -> String {
        let lastLine = [output.stdout, output.stderr].lazy.compactMap { stream in
            stream.split(whereSeparator: \.isNewline).last { !$0.allSatisfy(\.isWhitespace) }
        }.first
        guard let lastLine else {
            return "it exited with status \(output.exitCode) and printed no error."
        }
        return "\(ProviderMessageRedaction.redact(String(lastLine))) (exit status \(output.exitCode))"
    }

    /// A requested CLI is never swapped for another. An unconfirmed sign-in is tried, not refused.
    static func selectCLI(from detected: [DetectedAgentCLI],
                          preferredCLI: AgentCLI?) throws -> DetectedAgentCLI {
        if let preferredCLI {
            guard let preferred = detected.first(where: { $0.cli == preferredCLI }) else {
                throw EvaluationError.preferredAgentUnavailable(preferredCLI.displayName)
            }
            guard preferred.authenticationStatus != .signedOut else {
                throw EvaluationError.agentSignedOut(preferredCLI.displayName)
            }
            return preferred
        }
        if let ready = detected.first(where: { $0.authenticationStatus != .signedOut }) {
            return ready
        }
        guard let first = detected.first else { throw EvaluationError.noAgentCLI }
        throw EvaluationError.agentSignedOut(first.cli.displayName)
    }

    static func invocation(for cli: DetectedAgentCLI, prompt: String,
                           repositoryDirectory: URL, sessionDirectory: URL,
                           timeout: TimeInterval, isReleaseSource: Bool = false) -> AgentCLIRun {
        let arguments: [String]
        switch cli.cli {
        case .claude:
            // The prompt must directly follow `-p`: the variadic `--add-dir` would swallow it.
            arguments = [
                "-p", prompt,
                "--no-session-persistence",
                "--setting-sources", "",
                "--strict-mcp-config",
                "--permission-mode", "plan",
                "--add-dir", sessionDirectory.path,
            ]
        case .codex:
            // Release source is an archive with no `.git`, which Codex refuses by default.
            arguments = [
                "exec", "--ephemeral", "--sandbox", "read-only",
                "--ignore-user-config", "--ignore-rules",
                "-c", "mcp_servers={}",
            ] + (isReleaseSource ? ["--skip-git-repo-check"] : []) + [prompt]
        }
        return AgentCLIRun(
            executable: cli.executableURL,
            arguments: arguments,
            stdin: nil,
            workingDirectory: repositoryDirectory,
            timeout: timeout)
    }
}
