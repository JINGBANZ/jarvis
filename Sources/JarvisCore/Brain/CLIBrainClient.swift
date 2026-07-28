import Foundation

/// Brain client over a locally installed coding-agent CLI (`claude -p` / `codex exec`), so the brain
/// runs on the user's existing Claude / ChatGPT subscription instead of a metered API key. Each
/// `respond` is one self-contained subprocess run — no CLI session is created, resumed, or left
/// behind. The work is split by purpose: `+Conversation` flattens the client-managed messages,
/// `+Invocation` builds each provider's command line + audit record, and `+ReplyParsing` extracts
/// the CLI's final text. Coaching actions use `MCPBrainClient`; this client directly handles only
/// tool-less auxiliary calls. This file owns the configuration and request control flow.
///
/// `@unchecked Sendable` for the same reason as `OpenAIBrainClient`: all stored properties are
/// immutable, and `BrainTrafficLog` is internally synchronized.
public struct CLIBrainClient: BrainClient, @unchecked Sendable {
    /// Injected subprocess transport, the same seam shape as `OpenAIBrainClient.Sender` — tests
    /// fake it to assert the composed argv/stdin without spawning a process. The `AgentCLIPhaseTimings`
    /// is stamped by the runner as it reaches each observable boundary (a fake can stamp it to drive
    /// the phase-recording path deterministically).
    public typealias Runner = @Sendable (AgentCLIRun, AgentCLIPhaseTimings) async throws -> AgentCLIOutput

    public let provider: BrainProvider
    let executable: URL
    /// A CLI model id; empty retains the low-level invocation's CLI-default compatibility behavior.
    let model: String
    /// One global effort, mapped onto each CLI's own scale — `--effort` on Claude Code and
    /// `-c model_reasoning_effort=…` on Codex. Both CLI scales start at `low`, so `none` clamps to
    /// that floor while the shared `low` / `medium` / `high` levels pass through.
    let reasoningEffort: String
    let workDirectory: URL
    /// Enabled, non-removed feature names reported by this Codex installation. These are quiesced
    /// only for latency-sensitive MCP coaching runs; tool-less summarization keeps Codex's normal
    /// non-agentic feature profile. Empty keeps the prompt-only coaching restriction when the
    /// bounded capability probe was unavailable or malformed.
    let codexFeaturesToDisable: Set<String>
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
                codexFeaturesToDisable: Set<String> = [],
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
        self.codexFeaturesToDisable = codexFeaturesToDisable
        self.timeout = timeout ?? (provider == .codexCLI
                                   ? Self.codexDefaultTimeout : Self.defaultTimeout)
        self.traffic = traffic
        self.trafficTag = trafficTag
        self.run = run ?? { try await AgentCLIProcessRunner.run($0, timings: $1) }
    }

    public func respond(messages: [ChatMessage], tools: [ToolDef],
                        toolChoice: ToolChoice) async throws -> BrainResponse {
        do {
            guard tools.isEmpty else {
                throw BrainFailure(
                    disposition: .permanent,
                    detail: "local CLI coaching actions require MCP")
            }
            return try await performRequest(messages: messages)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            throw BrainFailure(error)
        }
    }

    /// Run the CLI with Jarvis's private MCP server as its only Jarvis-host effect surface. Returned
    /// text is diagnostic material only; the caller proves success from the shared attempt broker.
    public func respondUsingMCP(
        messages: [ChatMessage],
        tools: [ToolDef],
        toolChoice: ToolChoice,
        configuration: CLIMCPConfiguration,
        completionSignal: AgentCLICompletionSignal? = nil
    ) async throws -> BrainResponse {
        do {
            return try await performMCPRequest(
                messages: messages,
                tools: tools,
                toolChoice: toolChoice,
                configuration: configuration,
                completionSignal: completionSignal)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            throw BrainFailure(error)
        }
    }

    /// Keep classification at the provider boundary. CLI exit codes and stderr are diagnostics,
    /// not a recoverability taxonomy, so unclassified failures remain temporary by default.
    private func performRequest(messages: [ChatMessage]) async throws -> BrainResponse {
        // Monotonic t0 for the phase timings. `respondEntered` is the boundary `queuedMs` measures
        // from — prompt prep below plus dispatch onto the runner thread — and also drives the
        // traffic line's top-level total so the two duration fields cannot disagree.
        let timings = AgentCLIPhaseTimings()
        let respondEntered = DispatchTime.now().uptimeNanoseconds
        let prepared = try prepareInvocation(messages: messages)
        defer { for url in prepared.transientFiles { try? FileManager.default.removeItem(at: url) } }

        let output: AgentCLIOutput
        do {
            output = try await run(prepared.run, timings)
        } catch {
            // Preserve the phases completed before the failure (cancellation, timeout, provider
            // launch failure) — everything up to the throw is still on the recorder.
            let phases = Self.phaseDurationsMs(timings, respondEntered: respondEntered)
            logPhases(phases, note: "failed")
            traffic?.record(tag: trafficTag, request: Self.recordData(prepared.auditRequest),
                            response: nil, status: nil,
                            latencyMs: Self.totalLatencyMs(in: phases),
                            error: error.localizedDescription, phases: phases)
            throw error
        }
        // Record the round trip for the session audit — the extracted reply (not raw stdout, which
        // is stream noise), mapped to the HTTP-ish status the audit understands (exit 0 → 200,
        // anything else → 500). Extraction happens first so a parse failure is still recorded.
        let reply: String
        do {
            reply = try extractReply(output, codexReplyFile: prepared.codexReplyFile)
        } catch {
            let phases = Self.phaseDurationsMs(timings, respondEntered: respondEntered)
            logPhases(phases, note: "failed")
            traffic?.record(tag: trafficTag, request: Self.recordData(prepared.auditRequest),
                            response: responseRecord(output, reply: nil),
                            status: output.exitCode == 0 ? 200 : 500,
                            latencyMs: Self.totalLatencyMs(in: phases),
                            error: error.localizedDescription, phases: phases)
            throw error
        }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = BrainResponse(toolCalls: [], outputText: text.isEmpty ? nil : text)
        timings.mark(.replyParsed)
        let phases = Self.phaseDurationsMs(timings, respondEntered: respondEntered)
        logPhases(phases, note: "ok")
        traffic?.record(tag: trafficTag, request: Self.recordData(prepared.auditRequest),
                        response: responseRecord(output, reply: reply),
                        status: output.exitCode == 0 ? 200 : 500,
                        latencyMs: Self.totalLatencyMs(in: phases), phases: phases)

        return response
    }

    private func performMCPRequest(
        messages: [ChatMessage],
        tools: [ToolDef],
        toolChoice: ToolChoice,
        configuration: CLIMCPConfiguration,
        completionSignal: AgentCLICompletionSignal?
    ) async throws -> BrainResponse {
        let timings = AgentCLIPhaseTimings()
        let respondEntered = DispatchTime.now().uptimeNanoseconds
        let prepared = try prepareMCPInvocation(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            configuration: configuration,
            completionSignal: completionSignal)
        defer {
            for url in prepared.transientFiles {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let output: AgentCLIOutput
        do {
            output = try await run(prepared.run, timings)
        } catch {
            let phases = Self.phaseDurationsMs(timings, respondEntered: respondEntered)
            logPhases(phases, note: "mcp failed")
            traffic?.record(
                tag: trafficTag,
                request: Self.recordData(prepared.auditRequest),
                response: nil,
                status: nil,
                latencyMs: Self.totalLatencyMs(in: phases),
                error: error.localizedDescription,
                phases: phases)
            throw error
        }

        if output.termination == .completionSignal(.terminalActionDelivered) {
            // The brokered terminal action—not Codex's trailing prose—is the authoritative result.
            // Keep parseMs absent because no reply file was parsed, but retain the actual signal exit
            // code and partial diagnostics in the traffic record.
            let phases = Self.phaseDurationsMs(timings, respondEntered: respondEntered)
            logPhases(phases, note: "mcp terminal delivered")
            traffic?.record(
                tag: trafficTag,
                request: Self.recordData(prepared.auditRequest),
                response: responseRecord(output, reply: nil),
                status: 200,
                latencyMs: Self.totalLatencyMs(in: phases),
                phases: phases)
            return BrainResponse(
                toolCalls: [],
                outputText: nil,
                actionDelivery: .broker)
        }

        let reply: String
        do {
            reply = try extractReply(output, codexReplyFile: prepared.codexReplyFile)
        } catch {
            let phases = Self.phaseDurationsMs(timings, respondEntered: respondEntered)
            logPhases(phases, note: "mcp failed")
            traffic?.record(
                tag: trafficTag,
                request: Self.recordData(prepared.auditRequest),
                response: responseRecord(output, reply: nil),
                status: output.exitCode == 0 ? 200 : 500,
                latencyMs: Self.totalLatencyMs(in: phases),
                error: error.localizedDescription,
                phases: phases)
            throw error
        }

        timings.mark(.replyParsed)
        let phases = Self.phaseDurationsMs(timings, respondEntered: respondEntered)
        logPhases(phases, note: "mcp ok")
        traffic?.record(
            tag: trafficTag,
            request: Self.recordData(prepared.auditRequest),
            response: responseRecord(output, reply: reply),
            status: output.exitCode == 0 ? 200 : 500,
            latencyMs: Self.totalLatencyMs(in: phases),
            phases: phases)
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrainResponse(
            toolCalls: [],
            outputText: text.isEmpty ? nil : text,
            actionDelivery: .broker)
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
        if case .completionSignal(let reason) = output.termination {
            record["completion"] = reason.rawValue
        }
        let stderr = Self.tail(output.stderr)
        if !stderr.isEmpty { record["stderr"] = stderr }
        if provider == .claudeCode, var envelope = Self.claudeResultEnvelope(in: output.stdout) {
            envelope.removeValue(forKey: "result")
            record["cli"] = envelope
        }
        return Self.recordData(record)
    }

    // MARK: - Phase latency

    /// The named sub-phase latencies of one turn, in ms, for `brain-traffic.jsonl`. Each interval is
    /// present only when BOTH its boundary phases were observed — a phase that never happened (no
    /// stdout before a kill, no parse after a failure) is omitted, never recorded as zero. The
    /// boundaries and what each interval measures are documented on `AgentCLIPhaseTimings.Phase`;
    /// `totalMs` spans the whole `respond` from `respondEntered` to now, so a later warm-runtime
    /// change can compare cold vs warm at exactly these boundaries.
    static func phaseDurationsMs(_ t: AgentCLIPhaseTimings, respondEntered: UInt64) -> [String: Int] {
        let now = DispatchTime.now().uptimeNanoseconds
        func ms(_ from: UInt64?, _ to: UInt64?) -> Int? {
            guard let from, let to, to >= from else { return nil }
            return Int((to - from) / 1_000_000)
        }
        var phases: [String: Int] = [:]
        phases["queuedMs"] = ms(respondEntered, t.instant(.runnerEntered))
        phases["spawnMs"]  = ms(t.instant(.runnerEntered), t.instant(.processLaunched))
        phases["stdinMs"]  = ms(t.instant(.processLaunched), t.instant(.stdinDelivered))
        phases["firstOutputMs"] = ms(t.instant(.processLaunched), t.instant(.firstStdoutByte))
        phases["outputMs"]      = ms(t.instant(.firstStdoutByte), t.instant(.processExited))
        phases["parseMs"]       = ms(t.instant(.processExited), t.instant(.replyParsed))
        phases["totalMs"]       = ms(respondEntered, now)
        return phases   // assigning nil to a subscript omits the key — absent, not zero
    }

    static func totalLatencyMs(in phases: [String: Int]) -> Int {
        guard let total = phases["totalMs"] else {
            preconditionFailure("a completed phase snapshot always has a total")
        }
        return total
    }

    /// One concise diagnostic line per turn (raw timing detail belongs in `jarvis-debug.log`, never
    /// Activity). Lists only the phases that were observed, in boundary order.
    func logPhases(_ phases: [String: Int], note: String) {
        let order = [
            "queuedMs", "spawnMs", "stdinMs", "firstOutputMs", "outputMs", "parseMs", "totalMs",
        ]
        let parts = order.compactMap { key in phases[key].map { "\(key.dropLast(2))=\($0)ms" } }
        jlog("Jarvis \(trafficTag): \(provider.rawValue) CLI phases (\(note)) — "
             + parts.joined(separator: " "))
    }
}
