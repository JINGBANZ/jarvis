import Foundation
import JarvisCore

/// A one-shot `codex exec` runtime for auxiliary, non-coaching work.
///
/// Codex's coaching runtime is a session-scoped app-server that admits exactly one conversation at a
/// time. Sharing it with history compaction made a background summary able to fail the *next*
/// coaching attempt, and three such failures exhaust the target and advance the route — an auxiliary
/// chore taking out a brain provider. Spawning a short-lived process per summary removes the
/// contention rather than scheduling around it: there is nothing to share, and no ~100MB app-server
/// stays resident all session for a few seconds of work every few minutes.
///
/// The transport differs from the coach's; the safety envelope does not. `wiki/decisions.md` records
/// that Codex's `--disable` flags narrow nothing — the model is offered `exec`, `wait`,
/// `request_user_input`, and `collaboration` either way — and that the runtime item-event allowlist
/// is the control that actually bites. So this streams `codex exec --json` and applies the same
/// deny-by-default allowlist the app-server enforces, killing the process on anything else. Auth and
/// config isolation reuse the app-server's private `CODEX_HOME`.
struct CodexExecRuntime: LocalAgentRuntimeBackend {
    let transport = LocalAgentTransport.oneShotExec
    private let supportedFeatures: Set<String>
    private let homeBaseDirectory: URL
    private let lifetime = AgentRuntimeLifetime()

    init(
        supportedFeatures: Set<String> = [],
        homeBaseDirectory: URL = CodexRuntimeHome.defaultBaseDirectory
    ) {
        self.supportedFeatures = supportedFeatures
        self.homeBaseDirectory = homeBaseDirectory
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
            homeBaseDirectory: homeBaseDirectory,
            lifetime: lifetime)
    }

    func terminateNow() {
        lifetime.terminateAll()
    }
}

/// One `codex exec` invocation, streamed so a disallowed item can be caught while it happens.
private struct CodexExecConversation: LocalAgentConversation {
    let configuration: LocalAgentConversationConfiguration
    let supportedFeatures: Set<String>
    let homeBaseDirectory: URL
    let lifetime: AgentRuntimeLifetime

    /// The event stream a decision-only turn needs. Deny by default: Codex grows new tool item types
    /// over time, so an unrecognized one aborts rather than being waved through. `error` is a report,
    /// not an action, so it rides along and the turn is judged by its outcome.
    private static let allowedItemTypes: Set<String> = [
        "user_message",
        "agent_message",
        "reasoning",
        "error",
    ]

    func respond(
        to turn: LocalAgentTurn,
        onRequestDispatched: @Sendable () -> Void
    ) async throws -> LocalAgentTurnResult {
        try Task.checkCancellation()
        let deadline = Date().addingTimeInterval(turn.timeout)
        let home = try CodexRuntimeHome.create(in: homeBaseDirectory)
        defer { try? FileManager.default.removeItem(at: home) }

        let document = try document(for: turn)
        let process = try AgentRuntimeProcess(
            executable: configuration.executable,
            arguments: arguments(),
            workingDirectory: configuration.workDirectory,
            removingEnvironmentVariables: ["ANTHROPIC_API_KEY", "CLAUDECODE"],
            environmentOverrides: ["CODEX_HOME": home.path])
        try lifetime.register(process)
        defer {
            lifetime.unregister(process)
            process.terminateNow()
        }

        let dispatchedAt = DispatchTime.now().uptimeNanoseconds
        try await process.sendLine(document, timeout: max(0.01, deadline.timeIntervalSinceNow))
        process.closeStdin()   // exec reads its prompt to EOF before starting work
        onRequestDispatched()

        var firstAssistantAt: UInt64?
        var reply = ""
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw Self.error("codex exec timed out after \(Int(turn.timeout))s")
            }
            let line = try await process.nextLine(timeout: remaining)
            guard let event = try? JSONSerialization.jsonObject(
                with: Data(line.text.utf8)) as? [String: Any] else {
                continue   // `--json` still emits the odd human line; only events matter
            }
            try Self.rejectDisallowedItem(event)
            switch event["type"] as? String {
            case "item.started", "item.completed":
                guard Self.isAgentMessage(event) else { continue }
                if firstAssistantAt == nil { firstAssistantAt = line.observedAt }
                // The reply is read from the event, never from `--output-last-message`: that file is
                // written only after the process exits, so reading it at `turn.completed` finds
                // nothing. Measured against codex-cli — the item text is byte-identical to the file.
                if let text = (event["item"] as? [String: Any])?["text"] as? String, !text.isEmpty {
                    reply = text
                }
            case "turn.failed":
                throw Self.error("codex exec turn failed: \(Self.jsonDescription(event))")
            case "turn.completed":
                let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw Self.error("codex exec produced no reply")
                }
                // The completed turn carries the turn's token usage; keeping it is what lets the
                // session audit account for a compaction summary instead of reporting it unknown.
                return LocalAgentTurnResult(
                    reply: trimmed,
                    metadata: try? JSONSerialization.data(withJSONObject: event),
                    dispatchedAt: dispatchedAt,
                    firstAssistantAt: firstAssistantAt,
                    completedAt: line.observedAt)
            default:
                continue
            }
        }
    }

    func finish() async {}

    /// The app-server aborts a turn on any item event outside its message/reasoning allowlist. This
    /// path carries the same control: the disable flags are documented as narrowing nothing, so
    /// without it a prompt injection riding in transcript or OCR text could get a summary to run a
    /// built-in tool during the live pipeline.
    private static func rejectDisallowedItem(_ event: [String: Any]) throws {
        guard let type = event["type"] as? String, type.hasPrefix("item.") else { return }
        guard let item = event["item"] as? [String: Any],
              let itemType = item["type"] as? String,
              allowedItemTypes.contains(itemType) else {
            throw error("codex exec emitted a disallowed item event: \(jsonDescription(event))")
        }
    }

    private static func isAgentMessage(_ event: [String: Any]) -> Bool {
        (event["item"] as? [String: Any])?["type"] as? String == "agent_message"
    }

    /// Mirrors the hardening the coaching path applies: a read-only sandbox, no user config, project
    /// docs, or MCP servers, and every advertised agentic feature switched off. Codex is a coding
    /// agent even under `exec`, and this call is a text condensation, not an errand.
    private func arguments() -> [String] {
        var args = [
            "exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
            "--ignore-user-config", "--ignore-rules",
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
        var document = JarvisPrompts.LocalAgent.codexDirectResponse + "\n\n"
        if !configuration.instructions.isEmpty {
            document += configuration.instructions + "\n\n"
        }
        return document + blocks.joined(separator: "\n\n")
    }

    private static func jsonDescription(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object))
            .map { String(decoding: $0, as: UTF8.self) } ?? String(describing: object)
    }

    private static func error(_ detail: String) -> NSError {
        NSError(domain: "CodexExecRuntime", code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail])
    }
}
