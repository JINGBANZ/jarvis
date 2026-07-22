import Foundation

/// Building each provider's subprocess invocation — argv, stdin, transient files — together with
/// the session-audit record for the turn.
extension CLIBrainClient {
    /// Everything one turn needs to run and be audited. `transientFiles` (codex screenshot files,
    /// the codex reply file) are deleted by `respond` when the run finishes.
    struct PreparedInvocation {
        let run: AgentCLIRun
        let auditRequest: [String: Any]
        let transientFiles: [URL]
        let codexReplyFile: URL?
    }

    /// The audit record is built alongside the invocation with screenshots already redacted (never
    /// the raw stdin — an inline base64 image inside a JSON string would slip past
    /// `BrainTrafficLog.redactingImages`, which only recognizes parsed `data:` URIs). It reuses the
    /// evaluator's schema keys (model / instructions / input), so `SessionEvaluator` renders and
    /// prefix-elides CLI traffic exactly like API traffic.
    func prepareInvocation(messages: [ChatMessage], tools: [ToolDef],
                           toolChoice: ToolChoice) throws -> PreparedInvocation {
        let rendered = renderConversation(messages)
        // System text + tool protocol are the *instructions*; the conversation is the *input*.
        let instructions = composeInstructions(system: rendered.system, tools: tools,
                                               toolChoice: toolChoice)
        var auditRequest: [String: Any] = [
            "provider": provider.rawValue,
            "model": model.isEmpty ? "(CLI default)" : model,
            "executable": executable.path,
            "instructions": instructions,
        ]

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
            let message = try Self.claudeStreamMessage(segments: rendered.segments,
                                                       hasTools: !tools.isEmpty,
                                                       forcedTool: Self.forcedToolDirective(toolChoice))
            auditRequest["input"] = message.auditInput
            return PreparedInvocation(
                run: AgentCLIRun(executable: executable, arguments: args, stdin: message.stdin,
                                 workingDirectory: workDirectory, timeout: timeout),
                auditRequest: auditRequest, transientFiles: [], codexReplyFile: nil)

        case .codexCLI:
            // Codex exec has no system-prompt flag, so instructions + conversation travel as one
            // stdin document; screenshots become owner-only session-dir files attached via -i
            // (deleted after the run). read-only sandbox: the brain must not touch the filesystem
            // beyond reading its inputs. The final reply lands in --output-last-message (stdout is
            // a human-formatted log). --ephemeral mirrors claude's --no-session-persistence: no
            // rollout transcript in ~/.codex/sessions/. --ignore-user-config removes config.toml,
            // but NOT AGENTS.md or project discovery; explicit root/doc overrides keep the coding
            // harness out of this decision-only call. Codex has no general disable-all-tools flag,
            // so turn off only agentic feature names advertised by this installation's bounded
            // `features list` probe. The prompt below covers remaining/non-advertised built-ins,
            // while read-only stays the enforcement backstop. Auth still comes from CODEX_HOME.
            // "CLI default" means the built-in default. Verified against codex-cli 0.144.5.
            let replyFile = workDirectory.appendingPathComponent("cli-reply-\(UUID().uuidString.prefix(8)).txt")
            var transientFiles = [replyFile]
            var args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
                        "--ignore-user-config", "--ignore-rules",
                        "--output-last-message", replyFile.path,
                        "-c", "mcp_servers={}",
                        "-c", "project_root_markers=[]",
                        "-c", "project_doc_max_bytes=0",
                        "-c", "model_reasoning_effort=\(Self.codexEffort(reasoningEffort))"]
            for feature in Self.codexDisabledAgentFeatures where codexSupportedFeatures.contains(feature) {
                args += ["--disable", feature]
            }
            if !model.isEmpty { args += ["-m", model] }
            var blocks: [String] = []
            var auditInput: [[String: Any]] = []
            for segment in rendered.segments {
                switch segment {
                case .text(let block):
                    blocks.append(block)
                    auditInput.append(["type": "text", "text": block])
                case .imageJPEG(let base64):
                    let url = try writeImage(base64)
                    transientFiles.append(url)
                    args += ["-i", url.path]
                    blocks.append("[user]\n(screenshot attached as an image input)")
                    auditInput.append(["type": "image", "image": Self.imageStub(base64)])
                }
            }
            var document = Self.codexDirectResponseInstruction + "\n\n"
            if !instructions.isEmpty { document += instructions + "\n\n" }
            document += "## Conversation\n\n" + blocks.joined(separator: "\n\n")
            if !tools.isEmpty {
                document += "\n\nAnswer now, following the tool protocol."
                if let forced = Self.forcedToolDirective(toolChoice) { document += " \(forced)" }
            }
            auditRequest["input"] = auditInput
            return PreparedInvocation(
                run: AgentCLIRun(executable: executable, arguments: args, stdin: document,
                                 workingDirectory: workDirectory, timeout: timeout),
                auditRequest: auditRequest, transientFiles: transientFiles,
                codexReplyFile: replyFile)

        case .openAI:
            preconditionFailure("guarded in init")
        }
    }

    /// Codex is a coding agent even under `exec`; these feature gates remove built-in surfaces that
    /// can turn a three-way text decision into an agentic run. The invocation intersects this list
    /// with the installed CLI's advertised features, so renamed or unavailable names are omitted.
    static let codexDisabledAgentFeatures = [
        "apps",
        "browser_use",
        "code_mode_host",
        "computer_use",
        "goals",
        "image_generation",
        "multi_agent",
        "plugins",
        "shell_tool",
        "unified_exec",
    ]

    static let codexDirectResponseInstruction = """
        Answer this decision request immediately without inspecting files, running commands,
        browsing, planning, delegating, or invoking any Codex built-in tool. The capture_screen,
        speak, and stay_silent names below are an output JSON protocol, not callable Codex tools.
        """

    /// One stream-json user message carrying the whole conversation: text blocks coalesced,
    /// screenshots as inline base64 image blocks in their original positions. Inline images are why
    /// claude uses stream-json input at all — they reach the model in the same single call, where a
    /// file + Read tool would cost a second model round trip (and an on-disk copy). Also returns the
    /// audit copy of the content — same blocks with every image reduced to a stub — so the traffic
    /// log never receives the base64 bytes in any form.
    static func claudeStreamMessage(segments: [Segment], hasTools: Bool, forcedTool: String? = nil)
        throws -> (stdin: String, auditInput: [[String: Any]]) {
        var content: [[String: Any]] = []
        var auditInput: [[String: Any]] = []
        var textRun: [String] = ["## Conversation"]
        func flushText() {
            if !textRun.isEmpty {
                let block: [String: Any] = ["type": "text", "text": textRun.joined(separator: "\n\n")]
                content.append(block)
                auditInput.append(block)
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
                auditInput.append(["type": "image", "image": imageStub(base64)])
            }
        }
        if hasTools {
            var trailer = "Answer now, following the tool protocol."
            if let forcedTool { trailer += " \(forcedTool)" }
            textRun.append(trailer)
        }
        flushText()
        let message: [String: Any] = ["type": "user",
                                      "message": ["role": "user", "content": content]]
        let data = try JSONSerialization.data(withJSONObject: message)
        return (String(decoding: data, as: UTF8.self) + "\n", auditInput)
    }

    /// The audit-log stand-in for a screenshot — the pixels are already persisted as the session's
    /// `shot-N.jpg` files, so the record only needs to say one was sent (and how big).
    static func imageStub(_ base64: String) -> String {
        "[image/jpeg — \(base64.count) base64 chars, redacted]"
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

    // MARK: - Effort mapping

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
}
