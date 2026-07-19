import Foundation

/// Brain client over a locally installed coding-agent CLI (`claude -p` / `codex exec`), so the brain
/// runs on the user's existing Claude / ChatGPT subscription instead of a metered API key. Each
/// `respond` is one self-contained subprocess run — no CLI session is created, resumed, or left
/// behind. The work is split by purpose: `+Conversation` flattens the client-managed messages,
/// `+Invocation` builds each provider's command line + audit record, `+ReplyParsing` maps the CLI's
/// reply back into the same tool-call contract the Responses client speaks. This file owns the
/// configuration and the one `respond` control flow.
///
/// `@unchecked Sendable` for the same reason as `OpenAIBrainClient`: all stored properties are
/// immutable, and `BrainTrafficLog` is internally synchronized.
public struct CLIBrainClient: BrainClient, @unchecked Sendable {
    /// Injected subprocess transport, the same seam shape as `OpenAIBrainClient.Sender` — tests
    /// fake it to assert the composed argv/stdin without spawning a process.
    public typealias Runner = @Sendable (AgentCLIRun) async throws -> AgentCLIOutput

    let provider: BrainProvider
    let executable: URL
    /// A CLI model alias (`sonnet`, `gpt-5.5`, …); empty = the CLI's own configured default.
    let model: String
    /// One global effort, mapped onto each CLI's own scale — `--effort` on Claude Code (whose scale
    /// starts at `low`), `-c model_reasoning_effort=…` on Codex (which accepts ours unchanged).
    let reasoningEffort: String
    let workDirectory: URL
    let timeout: TimeInterval
    let traffic: BrainTrafficLog?
    let trafficTag: String
    let run: Runner

    /// A CLI turn pays process startup + agentic overhead on top of model latency, so the hang
    /// backstop sits well above the API client's. Still a backstop, not a latency knob.
    public static let defaultTimeout: TimeInterval = 120
    /// Healthy Codex coach turns take seconds. A silent agent-runtime stall must not leave the
    /// listening session green for two minutes while later transcript turns only batch behind it.
    public static let codexDefaultTimeout: TimeInterval = 30

    public init(provider: BrainProvider,
                executable: URL,
                model: String,
                reasoningEffort: String = ReasoningEffort.default.rawValue,
                workDirectory: URL,
                timeout: TimeInterval? = nil,
                traffic: BrainTrafficLog? = nil,
                trafficTag: String = "coach",
                run: Runner? = nil) {
        precondition(provider.usesLocalCLI, "CLIBrainClient needs a CLI provider, got \(provider)")
        self.provider = provider
        self.executable = executable
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.workDirectory = workDirectory
        self.timeout = timeout ?? (provider == .codexCLI
                                   ? Self.codexDefaultTimeout : Self.defaultTimeout)
        self.traffic = traffic
        self.trafficTag = trafficTag
        self.run = run ?? { try await AgentCLIProcessRunner.run($0) }
    }

    public func respond(messages: [ChatMessage], tools: [ToolDef],
                        toolChoice: ToolChoice) async throws -> BrainResponse {
        let prepared = try prepareInvocation(messages: messages, tools: tools, toolChoice: toolChoice)
        defer { for url in prepared.transientFiles { try? FileManager.default.removeItem(at: url) } }

        let started = Date()
        let output: AgentCLIOutput
        do {
            output = try await run(prepared.run)
        } catch {
            traffic?.record(tag: trafficTag, request: Self.recordData(prepared.auditRequest),
                            response: nil, status: nil,
                            latencyMs: Self.elapsedMs(since: started),
                            error: error.localizedDescription)
            throw error
        }
        // Record the round trip for the session audit — the extracted reply (not raw stdout, which
        // is stream noise), mapped to the HTTP-ish status the audit understands (exit 0 → 200,
        // anything else → 500). Extraction happens first so a parse failure is still recorded.
        let reply = Result { try extractReply(output, codexReplyFile: prepared.codexReplyFile) }
        traffic?.record(tag: trafficTag, request: Self.recordData(prepared.auditRequest),
                        response: responseRecord(output, reply: try? reply.get()),
                        status: output.exitCode == 0 ? 200 : 500,
                        latencyMs: Self.elapsedMs(since: started))

        return parse(reply: try reply.get(), tools: tools, toolChoice: toolChoice)
    }

    // MARK: - Audit records

    static func recordData(_ record: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: record)) ?? Data()
    }

    /// The audit-side view of one run: the extracted reply (raw stdout is stream noise), the exit
    /// code, any stderr, and — for claude — the result envelope's metadata (usage, duration,
    /// num_turns) with the reply itself removed rather than duplicated.
    func responseRecord(_ output: AgentCLIOutput, reply: String?) -> Data {
        var record: [String: Any] = ["exitCode": Int(output.exitCode)]
        if let reply { record["reply"] = reply }
        let stderr = Self.tail(output.stderr)
        if !stderr.isEmpty { record["stderr"] = stderr }
        if provider == .claudeCode, var envelope = Self.claudeResultEnvelope(in: output.stdout) {
            envelope.removeValue(forKey: "result")
            record["cli"] = envelope
        }
        return Self.recordData(record)
    }

    static func elapsedMs(since started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }
}
