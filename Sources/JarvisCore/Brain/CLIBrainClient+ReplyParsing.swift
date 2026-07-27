import Foundation

/// Mapping a finished run back into the brain contract by extracting the CLI's final reply text.
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
