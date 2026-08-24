import Foundation

/// One-ready-query Claude runtime. A lease is single-use at the coaching-attempt boundary, but the
/// leased query stays alive for every model turn in that attempt. Taking it immediately starts the
/// replacement so initialization overlaps remote inference.
actor ClaudeCodeRuntime: LocalAgentRuntimeBackend {
    private struct Preparation: Sendable {
        let id: UUID
        let task: Task<ClaudeCodeQuery, Error>
    }

    let auditLabel = "warm-query"
    private let lifetime = AgentRuntimeLifetime()
    private var configuration: LocalAgentConversationConfiguration?
    private var ready: ClaudeCodeQuery?
    private var preparing: Preparation?

    func prepare(for configuration: LocalAgentConversationConfiguration) async throws {
        try await prepare(
            for: configuration,
            deadline: Date().addingTimeInterval(configuration.timeout))
    }

    private func prepare(
        for configuration: LocalAgentConversationConfiguration,
        deadline: Date
    ) async throws {
        guard configuration.provider == .claudeCode else {
            preconditionFailure("ClaudeCodeRuntime received \(configuration.provider)")
        }
        if let existing = self.configuration, existing != configuration {
            throw Self.error("a Claude warm-query runtime cannot change configuration")
        }
        self.configuration = configuration
        if let ready, ready.isRunning {
            return
        }
        ready = nil
        startPreparationIfNeeded(configuration, deadline: deadline)
        guard let preparation = preparing else {
            throw Self.error("Claude warm-query preparation was unavailable")
        }
        do {
            let query = try await awaitPreparation(preparation)
            // Background prewarm and an attempt may await the same task. Only the first resumed
            // waiter may install it; a stale waiter must not overwrite a leased query/replacement.
            if preparing?.id == preparation.id {
                ready = query
                preparing = nil
            }
        } catch {
            if preparing?.id == preparation.id {
                preparing = nil
            }
            throw error
        }
    }

    func openConversation(
        for configuration: LocalAgentConversationConfiguration,
        deadline: Date
    )
        async throws -> any LocalAgentConversation {
        try await prepare(for: configuration, deadline: deadline)
        guard let query = ready else {
            throw Self.error("Claude warm query was not ready")
        }
        ready = nil
        startPreparationIfNeeded(configuration)
        return ClaudeCodeConversation(query: query)
    }

    nonisolated func terminateNow() {
        lifetime.terminateAll()
    }

    private func startPreparationIfNeeded(
        _ configuration: LocalAgentConversationConfiguration,
        deadline: Date? = nil
    ) {
        guard preparing == nil, ready == nil else { return }
        let lifetime = self.lifetime
        let preparationDeadline = deadline
            ?? Date().addingTimeInterval(configuration.timeout)
        preparing = Preparation(
            id: UUID(),
            task: Task.detached(priority: .utility) {
                try await ClaudeCodeQuery.start(
                    configuration: configuration,
                    deadline: preparationDeadline,
                    lifetime: lifetime)
            })
    }

    private func awaitPreparation(_ preparation: Preparation) async throws -> ClaudeCodeQuery {
        let lifetime = self.lifetime
        return try await withTaskCancellationHandler {
            try await preparation.task.value
        } onCancel: {
            preparation.task.cancel()
            lifetime.terminateAll()
        }
    }

    private static func error(_ detail: String) -> NSError {
        NSError(domain: "ClaudeCodeRuntime", code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail])
    }
}

private final class ClaudeCodeConversation: LocalAgentConversation, Sendable {
    private let query: ClaudeCodeQuery

    init(query: ClaudeCodeQuery) {
        self.query = query
    }

    func respond(
        to turn: LocalAgentTurn,
        onRequestDispatched: @Sendable () -> Void
    ) async throws -> LocalAgentTurnResult {
        try await query.respond(
            to: turn,
            onRequestDispatched: onRequestDispatched)
    }

    func finish() async {
        query.finish()
    }
}

/// `@unchecked Sendable` is justified because `finishLock` guards the only mutable property,
/// `finished`; the process and lifetime references provide their own synchronization.
private final class ClaudeCodeQuery: @unchecked Sendable {
    private let process: AgentRuntimeProcess
    private let lifetime: AgentRuntimeLifetime
    private let finishLock = NSLock()
    private var finished = false

    private init(process: AgentRuntimeProcess, lifetime: AgentRuntimeLifetime) {
        self.process = process
        self.lifetime = lifetime
    }

    deinit {
        finish()
    }

    var isRunning: Bool { process.isRunning }

    static func start(configuration: LocalAgentConversationConfiguration,
                      deadline: Date,
                      lifetime: AgentRuntimeLifetime) async throws -> ClaudeCodeQuery {
        var arguments = [
            "-p", "--verbose",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--no-session-persistence",
            "--safe-mode",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--mcp-config", #"{"mcpServers":{}}"#,
            "--system-prompt", configuration.instructions,
            "--effort", CLIBrainClient.claudeEffort(configuration.reasoningEffort),
            "--tools", "",
        ]
        if !configuration.model.isEmpty {
            arguments += ["--model", configuration.model]
        }

        let process = try AgentRuntimeProcess(
            executable: configuration.executable,
            arguments: arguments,
            workingDirectory: configuration.workDirectory,
            removingEnvironmentVariables: ["ANTHROPIC_API_KEY", "CLAUDECODE"])
        do {
            try lifetime.register(process)
            let query = ClaudeCodeQuery(process: process, lifetime: lifetime)
            let requestID = "jarvis_initialize_\(UUID().uuidString)"
            try await process.sendJSONObject([
                "type": "control_request",
                "request_id": requestID,
                "request": [
                    "subtype": "initialize",
                    "hooks": NSNull(),
                ],
            ], timeout: max(0.01, deadline.timeIntervalSinceNow))

            while true {
                let payload = try await query.nextPayload(deadline: deadline)
                guard payload["type"] as? String == "control_response",
                      let response = payload["response"] as? [String: Any],
                      response["request_id"] as? String == requestID else {
                    continue
                }
                guard response["subtype"] as? String == "success" else {
                    throw error("Claude initialize failed: \(Self.jsonDescription(response))")
                }
                let readyMs = Self.milliseconds(
                    from: process.launchedAt,
                    to: DispatchTime.now().uptimeNanoseconds)
                jlog("Jarvis: Claude Code warm query ready in \(readyMs)ms")
                return query
            }
        } catch {
            lifetime.unregister(process)
            process.terminateNow()
            throw error
        }
    }

    func respond(
        to turn: LocalAgentTurn,
        onRequestDispatched: @Sendable () -> Void
    ) async throws -> LocalAgentTurnResult {
        try Task.checkCancellation()
        let content: [[String: Any]] = turn.input.map { item in
            switch item {
            case .text(let text):
                return ["type": "text", "text": text]
            case .imageJPEG(let base64):
                return [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": base64,
                    ],
                ]
            }
        }
        let dispatchedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = Date().addingTimeInterval(turn.timeout)
        try await process.sendJSONObject([
            "type": "user",
            "message": [
                "role": "user",
                "content": content,
            ],
        ], timeout: max(0.01, deadline.timeIntervalSinceNow))
        onRequestDispatched()

        var firstAssistantAt: UInt64?
        var assistantText: String?
        var trace = StreamTrace()
        while true {
            let line: AgentRuntimeProcess.Line
            let payload: [String: Any]
            do {
                (line, payload) = try await nextPayloadWithLine(deadline: deadline)
            } catch {
                throw Self.describingTurnFailure(
                    error, budget: turn.timeout, dispatchedAt: dispatchedAt, trace: trace)
            }
            trace.record(payload)
            Self.logIfRateLimited(payload)
            switch payload["type"] as? String {
            case "assistant":
                if firstAssistantAt == nil {
                    firstAssistantAt = line.observedAt
                }
                guard let message = payload["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else {
                    continue
                }
                if blocks.contains(where: { $0["type"] as? String == "tool_use" }) {
                    throw Self.error("Claude emitted a built-in tool call in a tools-disabled turn")
                }
                let fragments = blocks.compactMap { block -> String? in
                    guard block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }
                if !fragments.isEmpty {
                    assistantText = fragments.joined()
                }
            case "result":
                let completedAt = line.observedAt
                if payload["is_error"] as? Bool == true
                    || (payload["subtype"] as? String).map({ $0 != "success" }) == true {
                    let detail = payload["result"] as? String
                        ?? Self.jsonDescription(payload)
                    throw Self.error(detail)
                }
                let reply = (payload["result"] as? String) ?? assistantText ?? ""
                var metadata = payload
                metadata.removeValue(forKey: "result")
                return LocalAgentTurnResult(
                    reply: reply,
                    metadata: try? JSONSerialization.data(withJSONObject: metadata),
                    dispatchedAt: dispatchedAt,
                    firstAssistantAt: firstAssistantAt,
                    completedAt: completedAt)
            case "control_request":
                throw Self.error("Claude requested unexpected control input")
            default:
                continue
            }
        }
    }

    func finish() {
        finishLock.lock()
        guard !finished else {
            finishLock.unlock()
            return
        }
        finished = true
        finishLock.unlock()
        process.terminateNow()
        lifetime.unregister(process)
    }

    private func nextPayload(deadline: Date) async throws -> [String: Any] {
        try await nextPayloadWithLine(deadline: deadline).payload
    }

    private func nextPayloadWithLine(deadline: Date)
        async throws -> (line: AgentRuntimeProcess.Line, payload: [String: Any]) {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                process.terminateNow()
                throw Self.deadlineExpired()
            }
            let line = try await process.nextLine(timeout: remaining)
            guard let payload = try? JSONSerialization.jsonObject(
                with: Data(line.text.utf8)) as? [String: Any] else {
                continue
            }
            return (line, payload)
        }
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Int {
        Int((end - start) / 1_000_000)
    }

    /// Marks the deadline expiring between reads, so `describingTurnFailure` can restate it with the
    /// same budget and stream detail it gives a timeout raised inside the read itself.
    private static func deadlineExpired() -> NSError {
        NSError(domain: "ClaudeCodeRuntime", code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "Claude response timed out"])
    }

    /// The process layer reports how long its final read waited, which is not the turn's budget: a
    /// turn that streams progress right up to the deadline leaves a sub-second last slice, which
    /// surfaced as the useless "timed out after 0s". Restate the failure against the budget that
    /// actually expired, and name the stream events that were in flight when it did.
    ///
    /// The original description is kept verbatim: `AgentRuntimeProcess` appends the CLI's stderr tail
    /// to its timeout, and that tail is often the most decisive evidence there is.
    private static func describingTurnFailure(
        _ error: Error,
        budget: TimeInterval,
        dispatchedAt: UInt64,
        trace: StreamTrace
    ) -> Error {
        let nsError = error as NSError
        let isRuntimeTimeout = nsError.domain == AgentRuntimeProcess.errorDomain
            && nsError.code == NSURLErrorTimedOut
        let isDeadlineBetweenReads = nsError.domain == "ClaudeCodeRuntime"
            && nsError.code == NSURLErrorTimedOut
        guard isRuntimeTimeout || isDeadlineBetweenReads else { return error }
        let elapsed = milliseconds(from: dispatchedAt, to: DispatchTime.now().uptimeNanoseconds)
        return Self.error(
            "Claude did not finish the turn within \(Int(budget))s "
            + "(elapsed \(elapsed)ms; \(trace.summary)) — \(nsError.localizedDescription)")
    }

    /// A throttled or rejected rate limit is the one discarded stream event that explains a stalled
    /// turn by itself, so it reaches the debug log instead of being dropped with the rest.
    private static func logIfRateLimited(_ payload: [String: Any]) {
        guard payload["type"] as? String == "rate_limit_event",
              let info = payload["rate_limit_info"] as? [String: Any],
              let status = info["status"] as? String,
              status != "allowed" else { return }
        jlog("Jarvis: Claude Code rate limit \(status) — \(jsonDescription(info))")
    }

    private static func jsonDescription(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object))
            .map { String(decoding: $0, as: UTF8.self) } ?? String(describing: object)
    }

    private static func error(_ detail: String) -> NSError {
        NSError(domain: "ClaudeCodeRuntime", code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail])
    }
}

/// A tally of what the CLI streamed during one turn.
///
/// Jarvis acts only on `assistant` and `result`, but the events it discards are the only evidence of
/// why a turn stalled: a timeout behind a run of `system/thinking_tokens` is a slow model, while one
/// that goes quiet after `rate_limit_event` is not. Counting them costs nothing and turns an opaque
/// timeout into a diagnosable one.
private struct StreamTrace {
    private var counts: [String: Int] = [:]

    mutating func record(_ payload: [String: Any]) {
        let type = payload["type"] as? String ?? "unknown"
        let kind = (payload["subtype"] as? String).map { "\(type)/\($0)" } ?? type
        counts[kind, default: 0] += 1
    }

    var summary: String {
        guard !counts.isEmpty else { return "no stream events" }
        return counts.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
    }
}
