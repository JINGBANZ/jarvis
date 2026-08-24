import Foundation

/// A one-shot `codex exec` runtime for auxiliary, non-coaching work.
///
/// Codex's coaching runtime is a session-scoped app-server that admits exactly one conversation at a
/// time. Sharing it with history compaction made a background summary able to fail the *next*
/// coaching attempt, and three such failures exhaust the target and advance the route — an auxiliary
/// chore taking out a brain provider. Spawning a short-lived process per summary removes the
/// contention rather than scheduling around it: there is nothing to share.
///
/// This is deliberately not a coaching path. It is text-only, keeps no state between turns, and has
/// nothing to warm, which is exactly why it cannot collide with the coach.
struct CodexExecRuntime: LocalAgentRuntimeBackend {
    private let supportedFeatures: Set<String>
    private let runs = ExecRunRegistry()

    init(supportedFeatures: Set<String> = []) {
        self.supportedFeatures = supportedFeatures
    }

    /// Nothing to warm: the process is the unit of work and lives only for one turn.
    func prepare(for configuration: LocalAgentConversationConfiguration) async throws {
        guard configuration.provider == .codexCLI else {
            preconditionFailure("CodexExecRuntime received \(configuration.provider)")
        }
    }

    /// `deadline` bounds runtime setup, of which there is none here; the turn's own timeout bounds
    /// the process.
    func openConversation(
        for configuration: LocalAgentConversationConfiguration,
        deadline: Date
    ) async throws -> any LocalAgentConversation {
        try await prepare(for: configuration)
        return CodexExecConversation(
            configuration: configuration,
            supportedFeatures: supportedFeatures,
            runs: runs)
    }

    func terminateNow() {
        runs.cancelAll()
    }
}

/// One `codex exec` invocation.
private struct CodexExecConversation: LocalAgentConversation {
    let configuration: LocalAgentConversationConfiguration
    let supportedFeatures: Set<String>
    let runs: ExecRunRegistry

    func respond(
        to turn: LocalAgentTurn,
        onRequestDispatched: @Sendable () -> Void
    ) async throws -> LocalAgentTurnResult {
        try Task.checkCancellation()
        // `codex exec` prints a human-formatted log to stdout; the reply itself lands in this file.
        // It holds transcript-derived text, so it stays inside the owner-only session directory and
        // is removed as soon as the turn ends.
        let replyFile = configuration.workDirectory
            .appendingPathComponent("codex-summary-\(UUID().uuidString.prefix(8)).txt")
        defer { try? FileManager.default.removeItem(at: replyFile) }

        let invocation = AgentCLIRun(
            executable: configuration.executable,
            arguments: arguments(replyFile: replyFile),
            stdin: try document(for: turn),
            workingDirectory: configuration.workDirectory,
            timeout: turn.timeout)

        let dispatchedAt = DispatchTime.now().uptimeNanoseconds
        onRequestDispatched()
        let output = try await runs.run(invocation)
        let completedAt = DispatchTime.now().uptimeNanoseconds

        let reply = (try? String(contentsOf: replyFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard output.exitCode == 0 else {
            throw Self.error(
                "codex exec failed (exit \(output.exitCode))"
                + (output.stderr.isEmpty ? "" : "; stderr: \(Self.tail(output.stderr))"))
        }
        guard !reply.isEmpty else {
            throw Self.error("codex exec produced no reply")
        }
        return LocalAgentTurnResult(
            reply: reply,
            metadata: nil,
            dispatchedAt: dispatchedAt,
            firstAssistantAt: nil,
            completedAt: completedAt)
    }

    func finish() async {}

    /// Mirrors the hardening the coaching path applies: a read-only sandbox, no user config, project
    /// docs, or MCP servers, and every advertised agentic feature switched off. Codex is a coding
    /// agent even under `exec`, and this call is a text condensation, not an errand.
    private func arguments(replyFile: URL) -> [String] {
        var args = [
            "exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
            "--ignore-user-config", "--ignore-rules",
            "--output-last-message", replyFile.path,
            "-c", "mcp_servers={}",
            "-c", "project_root_markers=[]",
            "-c", "project_doc_max_bytes=0",
            "-c", "model_reasoning_effort=\(CLIBrainClient.codexEffort(configuration.reasoningEffort))",
        ]
        for feature in CLIBrainClient.codexDisabledAgentFeatures
        where supportedFeatures.contains(feature) {
            args += ["--disable", feature]
        }
        if !configuration.model.isEmpty {
            args += ["-m", configuration.model]
        }
        return args
    }

    /// `codex exec` has no system-prompt flag, so the instructions and the text to condense travel
    /// as one stdin document.
    private func document(for turn: LocalAgentTurn) throws -> String {
        var blocks: [String] = []
        for item in turn.input {
            switch item {
            case .text(let text):
                blocks.append(text)
            case .imageJPEG:
                throw Self.error("the one-shot Codex runtime is text-only")
            }
        }
        var document = Self.directResponseInstruction + "\n\n"
        if !configuration.instructions.isEmpty {
            document += configuration.instructions + "\n\n"
        }
        return document + blocks.joined(separator: "\n\n")
    }

    private static let directResponseInstruction = """
        Answer this request immediately without inspecting files, running commands, browsing,
        planning, delegating, or invoking any Codex built-in tool. Reply with the requested text
        and nothing else.
        """

    private static func tail(_ text: String, limit: Int = 512) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.suffix(limit))
    }

    private static func error(_ detail: String) -> NSError {
        NSError(domain: "CodexExecRuntime", code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail])
    }
}

/// In-flight one-shot runs, so Stop keeps a synchronous kill path.
///
/// `AgentCLIProcessRunner` terminates its child when its task is cancelled, so holding the task is
/// enough to kill the process. `@unchecked Sendable` is justified because `tasks` and `isTerminated`
/// are only ever touched under `lock`.
private final class ExecRunRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<AgentCLIOutput, Error>] = [:]
    private var isTerminated = false

    func run(_ invocation: AgentCLIRun) async throws -> AgentCLIOutput {
        let id = UUID()
        // Deciding and spawning under one lock is what makes Stop authoritative: checking first and
        // spawning after would leave a window where a run launches just as termination lands, and
        // that process would outlive the session.
        let task: Task<AgentCLIOutput, Error> = try lock.withLock {
            if isTerminated { throw CancellationError() }
            let task = Task { try await AgentCLIProcessRunner.run(invocation) }
            tasks[id] = task
            return task
        }
        defer { lock.withLock { _ = tasks.removeValue(forKey: id) } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelAll() {
        let inFlight: [Task<AgentCLIOutput, Error>] = lock.withLock {
            isTerminated = true
            let all = Array(tasks.values)
            tasks.removeAll()
            return all
        }
        inFlight.forEach { $0.cancel() }
    }
}
