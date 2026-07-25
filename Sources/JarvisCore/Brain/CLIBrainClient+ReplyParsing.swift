import Foundation

/// Mapping a finished run back into the brain contract: extract the CLI's reply text, then parse
/// the prompt-embedded tool protocol out of it.
extension CLIBrainClient {
    /// The CLI's final reply text: Claude's from the `type:"result"` event of its stream-json
    /// output (the stream also carries system/assistant events — the result line is the envelope),
    /// Codex's from the `--output-last-message` file. A failed run throws with the most useful
    /// text available.
    func extractReply(_ output: AgentCLIOutput, codexReplyFile: URL?) throws -> String {
        if provider == .claudeCode, let envelope = Self.claudeResultEnvelope(in: output.stdout),
           let result = envelope["result"] as? String {
            if envelope["is_error"] as? Bool == true { throw Self.error(result, code: Int(output.exitCode)) }
            return result
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

    /// Claude's `type:"result"` stream event — the last line whose object carries a string
    /// `result` (the stream also emits system/assistant events).
    static func claudeResultEnvelope(in stdout: String) -> [String: Any]? {
        for line in stdout.split(separator: "\n").reversed() {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               obj["result"] is String {
                return obj
            }
        }
        return nil
    }

    /// Map the reply back into the brain contract. No tools → the text IS the payload (summarizer /
    /// evaluator). Otherwise parse the protocol JSON. Unlike the Responses API, a forced tool is
    /// only *prompted* here, so it's enforced client-side: a `force(speak)` turn (the hint hotkey)
    /// never accepts a different tool, and degrades to speaking the reply's prose — an explicit
    /// keypress must produce a visible hint, not silently vanish on a formatting slip.
    func parse(reply: String, tools: [ToolDef], toolChoice: ToolChoice) -> BrainResponse {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tools.isEmpty else {
            return BrainResponse(toolCalls: [], outputText: text.isEmpty ? nil : text)
        }
        let extracted = Self.extractToolCall(from: text)
        if let (name, argumentsJSON, _) = extracted {
            let callId = "cli_\(UUID().uuidString.prefix(8))"
            if case .force(let forced) = toolChoice, name != forced {
                jlog("Jarvis coach: CLI called '\(name)' where '\(forced)' was forced — recovering")
            } else if let invocation = ToolInvocation.parse(callId: callId, name: name,
                                                            argumentsJSON: argumentsJSON) {
                return BrainResponse(toolCalls: [invocation],
                                     rawToolCalls: [RawToolCall(id: callId, name: name,
                                                                argumentsJSON: argumentsJSON)])
            } else {
                jlog("Jarvis coach: CLI tool call '\(name)' was unknown or malformed")
            }
        }
        if case .force(let name) = toolChoice, name == speakTool.name {
            // Speak the reply's prose — everything before the (wrong or malformed) protocol
            // object, or the whole reply when there was none.
            let prose = extracted.map { String(text[..<$0.jsonStart]) } ?? text
            let lines = prose.split(separator: "\n").map(String.init)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.prefix(3)
            if !lines.isEmpty {
                let callId = "cli_\(UUID().uuidString.prefix(8))"
                // The recorded call must carry the lines actually shown: rawToolCalls is committed
                // to session history and replayed on later turns, so a `speak({})` there would
                // misreport what the user saw (and violate the speak schema).
                let argsJSON = (try? JSONSerialization.data(withJSONObject: ["lines": Array(lines)]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return BrainResponse(toolCalls: [.speak(callId: callId, lines: Array(lines))],
                                     rawToolCalls: [RawToolCall(id: callId, name: speakTool.name,
                                                                argumentsJSON: argsJSON)])
            }
        }
        // No usable tool call: preserve the text for traffic/debugging. The attempt runner treats
        // the missing required action as a failed attempt; deliberate silence is `stay_silent`.
        return BrainResponse(toolCalls: [], outputText: text.isEmpty ? nil : text)
    }

    /// Find the protocol object in the reply — the LAST parseable JSON object carrying a "tool" key,
    /// tolerating prose before it, a code fence around it, or `lines` flattened to the top level.
    /// `jsonStart` is where the object begins in `text`, so callers can recover the prose before it.
    static func extractToolCall(from text: String)
        -> (name: String, argumentsJSON: String, jsonStart: String.Index)? {
        // Length-preserving fence blanking (7 and 3 chars respectively), so indices into `cleaned`
        // remain valid indices into `text`.
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "\n      ")
            .replacingOccurrences(of: "```", with: "\n  ")
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
                return (name, argsJSON, start)
            }
        }
        return nil
    }

    // MARK: - Small shared helpers

    static func tail(_ s: String, max: Int = 2_000) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= max ? trimmed : String(trimmed.suffix(max))
    }

    static func error(_ message: String, code: Int = 1) -> NSError {
        NSError(domain: "CLIBrainClient", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
