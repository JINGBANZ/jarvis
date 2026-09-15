import Foundation
import JarvisCore

/// Mapping a persistent runtime's completed reply into the brain contract.
extension CLIBrainClient {
    /// Map the reply back into the brain contract. No tools → the text IS the payload (summarizer /
    /// evaluator). Otherwise report the protocol object as the model wrote it: the parsed call when
    /// `ToolInvocation.parse` accepts it, the raw call either way, and the prose before the object as
    /// `outputText`. The attempt runner reads every reply against the turn's tool choice, so a call a
    /// press may not make, a malformed call, and a press's prose are handled there, the same way on
    /// every transport.
    func parse(reply: String, tools: [ToolDef], toolChoice: ToolChoice) -> BrainResponse {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tools.isEmpty, let (name, argumentsJSON, jsonStart) = Self.extractToolCall(from: text) else {
            return BrainResponse(toolCalls: [], outputText: text.isEmpty ? nil : text)
        }
        let callId = "cli_\(UUID().uuidString.prefix(8))"
        let invocation = ToolInvocation.parse(callId: callId, name: name, argumentsJSON: argumentsJSON)
        if invocation == nil {
            jlog("Jarvis coach: CLI tool call '\(name)' was unknown or malformed")
        }
        let prose = text[..<jsonStart].trimmingCharacters(in: .whitespacesAndNewlines)
        return BrainResponse(
            toolCalls: invocation.map { [$0] } ?? [],
            rawToolCalls: [RawToolCall(id: callId, name: name, argumentsJSON: argumentsJSON)],
            outputText: prose.isEmpty ? nil : prose)
    }

    /// Find the protocol object in the reply — the LAST parseable JSON object carrying a "tool" key,
    /// tolerating prose before it, a code fence around it, or `lines` flattened to the top level.
    /// `jsonStart` is where the object begins in `text`, so callers can recover the prose before it.
    /// Public so session evidence readers read a recorded reply exactly as the client read it.
    public static func extractToolCall(from text: String)
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
