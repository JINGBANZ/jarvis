import Foundation

/// Brain client over a locally installed coding-agent CLI (`claude -p` / `codex exec`), so the brain
/// runs on the user's existing Claude / ChatGPT subscription instead of a metered API key. Each
/// `respond` is one self-contained subprocess run: the client-managed conversation is flattened into
/// a single prompt, the CLI's reply is parsed back into the same tool-call contract the Responses
/// client speaks (see `composeToolProtocol` — the model answers with one JSON object per turn).
///
/// Screenshots reach Claude INLINE as base64 image blocks (stream-json input — one model call, no
/// disk copy); Codex has no inline-image input, so for it they're written as owner-only (0600)
/// files into `workDirectory` — the per-session log directory, which already persists every
/// screenshot the model looks at (same data posture; see wiki/sandbox.md) — attached via `-i` and
/// deleted when the run finishes.
///
/// `@unchecked Sendable` for the same reason as `OpenAIBrainClient`: all stored properties are
/// immutable, and `BrainTrafficLog` is internally synchronized.
public struct CLIBrainClient: BrainClient, @unchecked Sendable {
    public typealias Runner = @Sendable (AgentCLIRun) async throws -> AgentCLIOutput

    private let provider: BrainProvider
    private let executable: URL
    /// A CLI model alias (`sonnet`, `gpt-5.5`, …); empty = the CLI's own configured default.
    private let model: String
    /// One global effort, mapped onto each CLI's own scale — `--effort` on Claude Code (whose scale
    /// starts at `low`), `-c model_reasoning_effort=…` on Codex (whose scale starts at `minimal`).
    private let reasoningEffort: String
    private let workDirectory: URL
    private let timeout: TimeInterval
    private let traffic: BrainTrafficLog?
    private let trafficTag: String
    private let run: Runner

    /// A CLI turn pays process startup + agentic overhead on top of model latency, so the hang
    /// backstop sits well above the API client's. Still a backstop, not a latency knob.
    public static let defaultTimeout: TimeInterval = 120

    public init(provider: BrainProvider,
                executable: URL,
                model: String,
                reasoningEffort: String = ReasoningEffort.default.rawValue,
                workDirectory: URL,
                timeout: TimeInterval = CLIBrainClient.defaultTimeout,
                traffic: BrainTrafficLog? = nil,
                trafficTag: String = "coach",
                run: Runner? = nil) {
        precondition(provider.usesLocalCLI, "CLIBrainClient needs a CLI provider, got \(provider)")
        self.provider = provider
        self.executable = executable
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.workDirectory = workDirectory
        self.timeout = timeout
        self.traffic = traffic
        self.trafficTag = trafficTag
        self.run = run ?? { try await AgentCLIProcessRunner.run($0) }
    }

    public func respond(messages: [ChatMessage], tools: [ToolDef],
                        toolChoice: ToolChoice) async throws -> BrainResponse {
        let rendered = renderConversation(messages)
        var transientFiles: [URL] = []
        defer { for url in transientFiles { try? FileManager.default.removeItem(at: url) } }

        // System text + tool protocol are the *instructions*; the conversation is the *input*.
        let instructions = composeInstructions(system: rendered.system, tools: tools,
                                               toolChoice: toolChoice)

        let invocation: AgentCLIRun
        var codexReplyFile: URL?
        switch provider {
        case .claudeCode:
            // --system-prompt REPLACES Claude Code's coding-agent persona with our instructions
            // (embedding them in the user prompt leaves the persona in charge — verified to make it
            // refuse the harness role); --setting-sources "" keeps user/project CLAUDE.md and
            // plugins out of the context; --tools "" disables every built-in tool, so a turn is
            // structurally ONE model call — screenshots ride INLINE as base64 image blocks via
            // --input-format stream-json (verified num_turns:1 on claude 2.1.211) instead of
            // costing a second model round trip through the Read tool.
            // --no-session-persistence: without it every turn leaves a session transcript (our
            // coach prompt + the user's speech) in ~/.claude/projects/ — outside the owner-only
            // session dir, violating the data posture. Memory is client-managed anyway; the CLI
            // session has no value to us. (No --max-turns in 2.1.211 — the runner's timeout is the
            // runaway guard; stream-json output requires --verbose.)
            // --strict-mcp-config with no --mcp-config = zero MCP servers: the coach must never
            // see (or bill for) the user's MCP tool surface, and a decision turn must not spin up
            // side-effecting servers. Keep the Jarvis invocation slim.
            var args = ["-p", "--verbose",
                        "--input-format", "stream-json",
                        "--output-format", "stream-json",
                        "--no-session-persistence",
                        "--setting-sources", "",
                        "--strict-mcp-config",
                        "--system-prompt", instructions,
                        "--effort", Self.claudeEffort(reasoningEffort),
                        "--tools", ""]
            if !model.isEmpty { args += ["--model", model] }
            let stdin = try Self.claudeStreamMessage(segments: rendered.segments,
                                                     hasTools: !tools.isEmpty)
            invocation = AgentCLIRun(executable: executable, arguments: args, stdin: stdin,
                                     workingDirectory: workDirectory, timeout: timeout)
        case .codexCLI:
            // Codex exec has no system-prompt flag, so instructions + conversation travel as one
            // stdin document; screenshots become owner-only session-dir files attached via -i
            // (deleted after the run). read-only sandbox: the brain must not touch the filesystem
            // beyond reading its inputs. The final reply lands in --output-last-message (stdout is
            // a human-formatted log). Verified against codex-cli 0.144.
            let replyFile = workDirectory.appendingPathComponent("cli-reply-\(UUID().uuidString.prefix(8)).txt")
            codexReplyFile = replyFile
            transientFiles.append(replyFile)
            // --ephemeral mirrors claude's --no-session-persistence: no rollout transcript in
            // ~/.codex/sessions/ — the conversation must exist only in our owner-only session dir.
            // mcp_servers={} disables every user-configured MCP server for this invocation — same
            // slimness rationale as claude's --strict-mcp-config (measured ~0.1s, but it keeps MCP
            // tool schemas out of the billed prompt and side-effecting servers out of a decision turn).
            var args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
                        "--output-last-message", replyFile.path,
                        "-c", "mcp_servers={}",
                        "-c", "model_reasoning_effort=\(Self.codexEffort(reasoningEffort))"]
            if !model.isEmpty { args += ["-m", model] }
            var blocks: [String] = []
            for segment in rendered.segments {
                switch segment {
                case .text(let block): blocks.append(block)
                case .imageJPEG(let base64):
                    let url = try writeImage(base64)
                    transientFiles.append(url)
                    args += ["-i", url.path]
                    blocks.append("[user]\n(screenshot attached as an image input)")
                }
            }
            var document = instructions.isEmpty ? "" : instructions + "\n\n"
            document += "## Conversation\n\n" + blocks.joined(separator: "\n\n")
            if !tools.isEmpty { document += "\n\nAnswer now, following the tool protocol." }
            invocation = AgentCLIRun(executable: executable, arguments: args, stdin: document,
                                     workingDirectory: workDirectory, timeout: timeout)
        case .openAI:
            preconditionFailure("guarded in init")
        }

        let started = Date()
        let output: AgentCLIOutput
        do {
            output = try await run(invocation)
        } catch {
            traffic?.record(tag: trafficTag, request: Self.requestRecord(invocation),
                            response: nil, status: nil,
                            latencyMs: Self.elapsedMs(since: started),
                            error: error.localizedDescription)
            throw error
        }
        // Record the raw round trip for the session audit, mapped to the HTTP-ish status the audit
        // understands (exit 0 → 200, anything else → 500).
        traffic?.record(tag: trafficTag, request: Self.requestRecord(invocation),
                        response: Self.responseRecord(output),
                        status: output.exitCode == 0 ? 200 : 500,
                        latencyMs: Self.elapsedMs(since: started))

        let reply = try extractReply(output, codexReplyFile: codexReplyFile)
        return parse(reply: reply, tools: tools, toolChoice: toolChoice)
    }

    // MARK: - Prompt composition

    /// One ordered piece of the flattened conversation: a labeled text block, or a screenshot in
    /// place. How a screenshot travels is the provider's business (inline block vs `-i` file).
    enum Segment {
        case text(String)
        case imageJPEG(base64: String)
    }

    private struct RenderedConversation {
        var system: [String] = []
        var segments: [Segment] = []
    }

    /// Flatten the wire-shaped messages into ordered segments. Assistant tool calls are replayed in
    /// the same JSON protocol the model answers with, so its past actions read exactly like the
    /// actions it can take now.
    private func renderConversation(_ messages: [ChatMessage]) -> RenderedConversation {
        var out = RenderedConversation()
        for m in messages {
            switch m.role {
            case .system:
                if let t = m.text { out.system.append(t) }
            case .user:
                if let base64 = m.imageBase64JPEG {
                    out.segments.append(.imageJPEG(base64: base64))
                } else {
                    out.segments.append(.text("[user]\n\(m.text ?? "")"))
                }
            case .assistant:
                if let calls = m.toolCalls {
                    for c in calls {
                        out.segments.append(.text("[assistant]\n{\"tool\":\"\(c.name)\",\"arguments\":\(c.argumentsJSON)}"))
                    }
                } else if let t = m.text {
                    out.segments.append(.text("[assistant]\n\(t)"))
                }
            case .tool:
                out.segments.append(.text("[tool result]\n\(m.text ?? "")"))
            }
        }
        return out
    }

    /// One stream-json user message carrying the whole conversation: text blocks coalesced,
    /// screenshots as inline base64 image blocks in their original positions. Inline images are why
    /// claude uses stream-json input at all — they reach the model in the same single call, where a
    /// file + Read tool would cost a second model round trip (and an on-disk copy).
    static func claudeStreamMessage(segments: [Segment], hasTools: Bool) throws -> String {
        var content: [[String: Any]] = []
        var textRun: [String] = ["## Conversation"]
        func flushText() {
            if !textRun.isEmpty {
                content.append(["type": "text", "text": textRun.joined(separator: "\n\n")])
                textRun = []
            }
        }
        for segment in segments {
            switch segment {
            case .text(let block):
                textRun.append(block)
            case .imageJPEG(let base64):
                textRun.append("[user]\n(screenshot below)")
                flushText()
                content.append(["type": "image",
                                "source": ["type": "base64", "media_type": "image/jpeg",
                                           "data": base64]])
            }
        }
        if hasTools { textRun.append("Answer now, following the tool protocol.") }
        flushText()
        let message: [String: Any] = ["type": "user",
                                      "message": ["role": "user", "content": content]]
        let data = try JSONSerialization.data(withJSONObject: message)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The instruction block: the system text plus the tool protocol. Passed as `--system-prompt`
    /// on Claude Code; prepended to the stdin document on Codex.
    private func composeInstructions(system: [String], tools: [ToolDef],
                                     toolChoice: ToolChoice) -> String {
        var sections = system
        if !tools.isEmpty { sections.append(composeToolProtocol(tools: tools, toolChoice: toolChoice)) }
        return sections.joined(separator: "\n\n")
    }

    /// The CLI-side stand-in for the Responses API's native function calling: the model is told to
    /// end its reply with one JSON object naming the tool. Generated from the same `ToolDef`s the
    /// API client sends, so the two providers stay behaviorally interchangeable.
    private func composeToolProtocol(tools: [ToolDef], toolChoice: ToolChoice) -> String {
        var lines = ["## Tool protocol",
                     "",
                     "You are the decision engine inside an automated harness — your reply is parsed "
                     + "by a program, not read by a person. These are your tools:"]
        for t in tools {
            lines.append("- \(t.name) — \(t.description)")
            lines.append("  arguments JSON Schema: \(t.parametersJSON)")
        }
        lines.append("")
        lines.append("End your reply with a single line containing ONLY this JSON object (no code "
                     + "fence, nothing after it): {\"tool\":\"<tool name>\",\"arguments\":{…}}. "
                     + "Use {} for a tool with no arguments.")
        switch toolChoice {
        case .required:
            lines.append("You MUST pick exactly one tool this turn — the JSON object is your entire answer.")
        case .force(let name):
            lines.append("You MUST call the `\(name)` tool this turn.")
        case .auto:
            lines.append("If no tool fits, reply with plain text instead of the JSON object.")
        }
        return lines.joined(separator: "\n")
    }

    private func writeImage(_ base64: String) throws -> URL {
        guard let data = Data(base64Encoded: base64) else {
            throw Self.error("screenshot payload was not valid base64")
        }
        let url = workDirectory.appendingPathComponent("cli-shot-\(UUID().uuidString.prefix(8)).jpg")
        // 0600 from the start, matching every other screen-derived file in the session directory.
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw Self.error("couldn't write screenshot for the CLI at \(url.path)")
        }
        return url
    }

    // MARK: - Reply extraction

    /// The CLI's final reply text: Claude's from the `type:"result"` event of its stream-json
    /// output (the stream also carries system/assistant events — the result line is the envelope),
    /// Codex's from the `--output-last-message` file. A failed run throws with the most useful
    /// text available.
    private func extractReply(_ output: AgentCLIOutput, codexReplyFile: URL?) throws -> String {
        if provider == .claudeCode {
            for line in output.stdout.split(separator: "\n").reversed() {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let result = obj["result"] as? String else { continue }
                if obj["is_error"] as? Bool == true { throw Self.error(result, code: Int(output.exitCode)) }
                return result
            }
        }
        if let codexReplyFile, let reply = try? String(contentsOf: codexReplyFile, encoding: .utf8),
           !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard output.exitCode == 0 else {
                throw Self.error(Self.tail(output.stderr), code: Int(output.exitCode))
            }
            return reply
        }
        guard output.exitCode == 0 else {
            let detail = [Self.tail(output.stderr), Self.tail(output.stdout)]
                .filter { !$0.isEmpty }.joined(separator: "\n")
            throw Self.error(detail.isEmpty ? "exit \(output.exitCode)" : detail,
                             code: Int(output.exitCode))
        }
        // Envelope/file missing on a clean exit (e.g. an older CLI): fall back to raw stdout.
        return output.stdout
    }

    /// Map the reply back into the brain contract. No tools → the text IS the payload (summarizer /
    /// evaluator). Otherwise parse the protocol JSON; a forced `speak` whose JSON didn't parse
    /// degrades to speaking the raw reply — an explicit hotkey press must produce a visible hint,
    /// not silently vanish on a formatting slip.
    private func parse(reply: String, tools: [ToolDef], toolChoice: ToolChoice) -> BrainResponse {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tools.isEmpty else {
            return BrainResponse(toolCalls: [], outputText: text.isEmpty ? nil : text)
        }
        if let (name, argumentsJSON) = Self.extractToolCall(from: text) {
            let callId = "cli_\(UUID().uuidString.prefix(8))"
            if let invocation = ToolInvocation.parse(callId: callId, name: name,
                                                     argumentsJSON: argumentsJSON) {
                return BrainResponse(toolCalls: [invocation],
                                     rawToolCalls: [RawToolCall(id: callId, name: name,
                                                                argumentsJSON: argumentsJSON)])
            }
            jlog("Jarvis coach: CLI called unknown tool '\(name)'")
        }
        if case .force(let name) = toolChoice, name == speakTool.name, !text.isEmpty {
            let lines = text.split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty }.prefix(3)
            let callId = "cli_\(UUID().uuidString.prefix(8))"
            return BrainResponse(toolCalls: [.speak(callId: callId, lines: Array(lines))],
                                 rawToolCalls: [RawToolCall(id: callId, name: speakTool.name,
                                                            argumentsJSON: "{}")])
        }
        // No parseable tool call: surface the text and let the driver treat it as silence.
        return BrainResponse(toolCalls: [], outputText: text.isEmpty ? nil : text)
    }

    /// Find the protocol object in the reply — the LAST parseable JSON object carrying a "tool" key,
    /// tolerating prose before it, a code fence around it, or `lines` flattened to the top level.
    static func extractToolCall(from text: String) -> (name: String, argumentsJSON: String)? {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "\n")
            .replacingOccurrences(of: "```", with: "\n")
        var braceIndices: [String.Index] = []
        var search = cleaned.startIndex
        while let r = cleaned.range(of: "{", range: search..<cleaned.endIndex) {
            braceIndices.append(r.lowerBound)
            search = r.upperBound
        }
        let lastClose = cleaned.range(of: "}", options: .backwards)?.upperBound
        for start in braceIndices.reversed() {
            var candidates = [String(cleaned[start...])]
            if let lastClose, lastClose > start { candidates.append(String(cleaned[start..<lastClose])) }
            for candidate in candidates {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
                      let name = obj["tool"] as? String else { continue }
                // Arguments either nested under "arguments" or flattened beside "tool".
                let args = (obj["arguments"] as? [String: Any]) ?? obj.filter { $0.key != "tool" }
                let argsJSON = (try? JSONSerialization.data(withJSONObject: args))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return (name, argsJSON)
            }
        }
        return nil
    }

    // MARK: - Support

    /// Codex's current models accept exactly our scale (none/low/medium/high, plus xhigh) — and
    /// REJECT the older "minimal" (verified: a 400 on codex 0.144 / gpt-5.6-sol), so the value
    /// passes through unmapped.
    static func codexEffort(_ effort: String) -> String {
        effort
    }

    /// Claude Code's `--effort` scale starts at "low" (low/medium/high/xhigh/max); ours starts at
    /// "none", which clamps to the CLI's floor. The shared levels match.
    static func claudeEffort(_ effort: String) -> String {
        effort == ReasoningEffort.none.rawValue ? ReasoningEffort.low.rawValue : effort
    }

    private static func requestRecord(_ invocation: AgentCLIRun) -> Data {
        let record: [String: Any] = [
            "executable": invocation.executable.path,
            "arguments": invocation.arguments,
            "prompt": invocation.stdin ?? "",
        ]
        return (try? JSONSerialization.data(withJSONObject: record)) ?? Data()
    }

    private static func responseRecord(_ output: AgentCLIOutput) -> Data {
        let record: [String: Any] = [
            "exitCode": Int(output.exitCode),
            "stdout": output.stdout,
            "stderr": tail(output.stderr),
        ]
        return (try? JSONSerialization.data(withJSONObject: record)) ?? Data()
    }

    private static func tail(_ s: String, max: Int = 2_000) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= max ? trimmed : String(trimmed.suffix(max))
    }

    private static func error(_ message: String, code: Int = 1) -> NSError {
        NSError(domain: "CLIBrainClient", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func elapsedMs(since started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }
}
