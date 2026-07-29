import Foundation

/// Mapping a persistent runtime's completed reply into the brain contract.
extension CLIBrainClient {
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

}
