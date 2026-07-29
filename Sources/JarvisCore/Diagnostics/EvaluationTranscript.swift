import Foundation

/// Delta-aware rendering of a session's wire traffic for `AgenticEvaluation`. The harness rebuilds
/// every request as `[system] + history + turn`, so consecutive requests repeat almost all of their
/// input. Unchanged instructions, tools, and input prefixes are elided and explicitly marked; the
/// complete un-elided `brain-traffic.jsonl` remains available to the agent for exact counts.
enum EvaluationTranscript {

    /// Render the recorded traffic as a readable transcript, one block per round trip, eliding
    /// request content that is byte-identical to the previous call with the same tag (see the type
    /// comment). Malformed lines are skipped; an empty/blank file renders as "".
    static func render(jsonl: String) -> String {
        var blocks: [String] = []
        // Elision state, per logical client and provider/model destination.
        var prevInstructions: [String: String] = [:]
        var prevTools: [String: String] = [:]
        var prevInput: [String: [String]] = [:]
        var callNumber = 0

        for raw in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            else { continue }
            callNumber += 1
            let tag = entry["tag"] as? String ?? "?"
            let request = entry["request"] as? [String: Any]
            let response = entry["response"] as? [String: Any]
            let provider = SessionMetrics.providerName(request: request, response: response)
            // A session can fail over while keeping the same logical client tag. Prefix-elision state
            // must not cross provider/model targets: their wire schemas, cache behavior, and
            // tool-loop state can differ.
            let model = request?["model"] as? String ?? "?"
            let streamKey = "\(tag)\u{1F}\(provider)\u{1F}\(model)"
            var lines: [String] = []

            var header = "=== call #\(callNumber) · \(tag) · \(entry["t"] as? String ?? "?")"
            header += " · \(provider)"
            if let status = entry["status"] as? Int { header += " · HTTP \(status)" }
            if let ms = entry["ms"] as? Int { header += " · \(ms) ms" }
            lines.append(header)
            if let error = entry["error"] as? String { lines.append("TRANSPORT ERROR: \(error)") }

            if let request {
                lines.append(contentsOf: renderRequest(request, tag: tag, streamKey: streamKey,
                                                       prevInstructions: &prevInstructions,
                                                       prevTools: &prevTools,
                                                       prevInput: &prevInput))
            }
            if let response = entry["response"] {
                lines.append(contentsOf: renderResponse(response))
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        guard !blocks.isEmpty else { return "" }
        // Lead with the deterministic metrics table (computed, not eyeballed) so the auditor
        // interprets numbers instead of summing usage blobs by hand — the source of the 2026-07-19
        // audit's cost/cache arithmetic errors. Empty traffic still renders "" (callers guard on it).
        let body = blocks.joined(separator: "\n\n")
        return SessionMetrics.render(jsonl: jsonl) + "\n\n" + body
    }

    private static func renderRequest(_ request: [String: Any], tag: String, streamKey: String,
                                      prevInstructions: inout [String: String],
                                      prevTools: inout [String: String],
                                      prevInput: inout [String: [String]]) -> [String] {
        var lines: [String] = []
        var params = "request: model=\(request["model"] as? String ?? "?")"
        if let reasoning = request["reasoning"] { params += " reasoning=\(compact(reasoning))" }
        if let cap = request["max_output_tokens"] { params += " max_output_tokens=\(cap)" }
        if let choice = request["tool_choice"] { params += " tool_choice=\(compact(choice))" }
        lines.append(params)

        let instructions = request["instructions"] as? String ?? ""
        if instructions == prevInstructions[streamKey] {
            lines.append("instructions: (unchanged — \(instructions.count) chars)")
        } else if !instructions.isEmpty {
            lines.append("instructions (\(instructions.count) chars):\n\(instructions)")
        }
        prevInstructions[streamKey] = instructions

        let tools = canonical(request["tools"] ?? [])
        if tools == prevTools[streamKey] {
            let count = (request["tools"] as? [Any])?.count ?? 0
            lines.append("tools: (unchanged — \(count) defs)")
        } else {
            lines.append("tools: \(tools)")
        }
        prevTools[streamKey] = tools

        let items = request["input"] as? [Any] ?? []
        let rendered = items.map { renderInputItem($0) }
        let canon = items.map { canonical($0) }
        let prev = prevInput[streamKey] ?? []
        var shared = 0
        while shared < min(canon.count, prev.count), canon[shared] == prev[shared] { shared += 1 }
        lines.append("input (\(items.count) items):")
        if shared > 0 {
            lines.append("  [items 1–\(shared) unchanged from the previous \(tag) call — the stable, cacheable prefix]")
        }
        lines.append(contentsOf: rendered.dropFirst(shared).map { "  \($0)" })
        prevInput[streamKey] = canon
        return lines
    }

    /// Flatten one Responses `input` item to a single labelled line: role messages get their text
    /// (image parts were already redacted at record time), function calls/results get name + payload.
    private static func renderInputItem(_ item: Any) -> String {
        guard let dict = item as? [String: Any] else { return compact(item) }
        if let role = dict["role"] as? String {
            let content = (dict["content"] as? [[String: Any]] ?? [])
                .compactMap { ($0["text"] ?? $0["image_url"]) as? String }
                .joined(separator: "\n")
            return "\(role): \(content)"
        }
        switch dict["type"] as? String {
        case "function_call":
            return "assistant → function_call \(dict["name"] as? String ?? "?")(\(dict["arguments"] as? String ?? ""))"
        case "function_call_output":
            return "tool result: \(dict["output"] as? String ?? "")"
        case "reasoning":
            // The tool loop replays reasoning items verbatim (opaque ids, possibly a large
            // `encrypted_content` blob) — no audit signal in the bytes, so stub them like images.
            return "assistant reasoning (replayed verbatim — \(compact(dict).count) chars)"
        // CLI-provider records (`CLIBrainClient`): plain content blocks, images already stubbed.
        case "text":
            return "text: \(dict["text"] as? String ?? "")"
        case "image":
            return "image: \(dict["image"] as? String ?? "(redacted)")"
        default:
            return compact(dict)
        }
    }

    private static func renderResponse(_ response: Any) -> [String] {
        guard let dict = response as? [String: Any] else { return ["response (unparsed): \(compact(response))"] }
        var lines: [String] = []
        var header = "response:"
        if let status = dict["status"] as? String { header += " status=\(status)" }
        if let details = dict["incomplete_details"] { header += " incomplete_details=\(compact(details))" }
        if let exit = dict["exitCode"] as? Int { header += " exit=\(exit)" }   // CLI-provider record
        lines.append(header)
        for item in dict["output"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "function_call":
                lines.append("  → function_call \(item["name"] as? String ?? "?")(\(item["arguments"] as? String ?? ""))")
            case "message":
                let text = (item["content"] as? [[String: Any]] ?? [])
                    .compactMap { $0["text"] as? String }
                    .joined()
                lines.append("  → text: \(text)")
            case "reasoning":
                continue   // encrypted/empty reasoning stubs carry no signal
            default:
                lines.append("  → \(compact(item))")
            }
        }
        // CLI-provider records carry the reply as one string plus the CLI's own envelope metadata
        // (usage/duration for claude) instead of a Responses `output` array.
        if let reply = dict["reply"] as? String, !reply.isEmpty { lines.append("  → text: \(reply)") }
        if let cli = dict["cli"] { lines.append("  cli: \(compact(cli))") }
        if let runtime = dict["runtime"] { lines.append("  runtime: \(compact(runtime))") }
        if let stderr = dict["stderr"] as? String, !stderr.isEmpty { lines.append("  stderr: \(stderr)") }
        // Usage is the quantitative core of the audit: `input_tokens_details.cached_tokens` vs
        // `input_tokens` is the prompt-cache hit rate, per call.
        if let usage = dict["usage"] { lines.append("  usage: \(compact(usage))") }
        if let error = dict["error"], !(error is NSNull) { lines.append("  API ERROR: \(compact(error))") }
        return lines
    }

    /// Deterministic single-line JSON for both display and prefix comparison.
    private static func canonical(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.sortedKeys, .fragmentsAllowed])
        else { return String(describing: value) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func compact(_ value: Any) -> String { canonical(value) }
}
