import Foundation

/// Delta-aware rendering of a session's wire traffic for `AgenticEvaluation`. The harness rebuilds
/// every request as `[system] + history + turn`, so consecutive requests repeat almost all of their
/// input. Unchanged instructions, tools, and input prefixes are elided and explicitly marked; the
/// complete un-elided `brain-traffic.jsonl` remains available to the agent for exact counts.
enum EvaluationTranscript {

    /// Render the recorded traffic as a readable transcript, one block per traffic record, eliding
    /// request content that is byte-identical to the previous call with the same tag (see the type
    /// comment). Malformed and pre-request records stay explicit; an empty/blank file renders as "".
    static func render(
        jsonl: String,
        attemptsJSONL: String? = nil,
        activityJSONL: String? = nil
    ) -> String {
        var blocks: [String] = []
        // Elision state, per logical client and provider/model destination.
        var prevInstructions: [String: String] = [:]
        var prevTools: [String: String] = [:]
        var prevInput: [String: [String]] = [:]
        var prevInputText: [String: [String?]] = [:]
        let records = JSONLRecords.parse(jsonl)
        for record in records.lines {
            guard let entry = record.object else {
                blocks.append(
                    "=== record #\(record.number) · malformed traffic entry · evidence unavailable; inspect \(BrainTrafficLog.filename) ===")
                continue
            }
            let callNumber = record.number
            let tag = entry["tag"] as? String ?? "?"
            let request = entry["request"] as? [String: Any]
            let response = entry["response"] as? [String: Any]
            let provider = SessionMetrics.providerName(request: request, response: response)
            let isPreRequestFailure = entry["record_kind"] as? String
                == BrainTrafficLog.RecordKind.preRequestFailure.rawValue
            // A session can fail over while keeping the same logical client tag. Prefix-elision state
            // must not cross provider/model targets: their wire schemas, cache behavior, and
            // tool-loop state can differ.
            let model = request?["model"] as? String ?? "?"
            let streamKey = "\(tag)\u{1F}\(provider)\u{1F}\(model)"
            var lines: [String] = []

            let recordLabel = isPreRequestFailure ? "record" : "call"
            var header = "=== \(recordLabel) #\(callNumber) · \(tag) · \(entry["t"] as? String ?? "?")"
            header += " · \(provider)"
            if let status = entry["status"] as? Int { header += " · HTTP \(status)" }
            if let ms = entry["ms"] as? Int { header += " · \(ms) ms" }
            if let provenance = entry["coach_attempt"] as? [String: Any] {
                if let id = provenance["id"] as? Int { header += " · attempt #\(id)" }
                if let trigger = provenance["trigger"] as? String {
                    header += " · trigger=\(trigger)"
                }
                if let phase = provenance["phase"] as? String {
                    header += " · phase=\(phase)"
                }
            } else if tag == "coach" {
                header += " · trigger=unavailable"
            }
            if isPreRequestFailure {
                header += " · pre-request failure (no provider call)"
            }
            lines.append(header)
            if let error = entry["error"] as? String { lines.append("TRANSPORT ERROR: \(error)") }

            if let request {
                lines.append(contentsOf: renderRequest(request, tag: tag, streamKey: streamKey,
                                                       prevInstructions: &prevInstructions,
                                                       prevTools: &prevTools,
                                                       prevInput: &prevInput,
                                                       prevInputText: &prevInputText))
            }
            if let response = entry["response"] {
                lines.append(contentsOf: renderResponse(response, tag: tag))
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        guard !blocks.isEmpty else { return "" }
        // Lead with the deterministic metrics table (computed, not eyeballed) so the auditor
        // interprets numbers instead of summing usage blobs by hand — the source of the 2026-07-19
        // audit's cost/cache arithmetic errors. Empty traffic still renders "" (callers guard on it).
        let body = blocks.joined(separator: "\n\n")
        let triggerMetrics = TriggerQualityMetrics.render(
            trafficJSONL: jsonl,
            attemptsJSONL: attemptsJSONL,
            activityJSONL: activityJSONL)
        return SessionMetrics.render(jsonl: jsonl) + "\n\n" + triggerMetrics + "\n\n" + body
    }

    private static func renderRequest(_ request: [String: Any], tag: String, streamKey: String,
                                      prevInstructions: inout [String: String],
                                      prevTools: inout [String: String],
                                      prevInput: inout [String: [String]],
                                      prevInputText: inout [String: [String?]]) -> [String] {
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
        let canon = items.map { canonical($0) }
        let prev = prevInput[streamKey] ?? []
        let previousText = prevInputText[streamKey] ?? []
        let currentText = items.map(cliText)
        var shared = 0
        while shared < min(canon.count, prev.count), canon[shared] == prev[shared] { shared += 1 }
        lines.append("brain request input (\(items.count) items):")
        if shared > 0 {
            lines.append("  [items 1–\(shared) unchanged from the previous \(tag) call — the stable, cacheable prefix]")
        }
        for index in shared..<items.count {
            lines.append("  " + renderInputItem(
                items[index],
                previousCLIText: index < previousText.count ? previousText[index] : nil,
                tag: tag))
        }
        prevInput[streamKey] = canon
        prevInputText[streamKey] = currentText
        return lines
    }

    /// Flatten one Responses `input` item to a single labelled line: role messages get their text
    /// (image parts were already redacted at record time), function calls/results get name + payload.
    private static func renderInputItem(
        _ item: Any,
        previousCLIText: String?,
        tag: String
    ) -> String {
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
            let text = dict["text"] as? String ?? ""
            return "text: " + renderCLITextDelta(text, previous: previousCLIText, tag: tag)
        case "image":
            return "image: \(dict["image"] as? String ?? "(redacted)")"
        default:
            return compact(dict)
        }
    }

    private static func renderResponse(_ response: Any, tag: String) -> [String] {
        let outputLabel = tag == "coach" ? "Jarvis brain output" : "\(tag) brain output"
        guard let dict = response as? [String: Any] else {
            return ["\(outputLabel) (unparsed): \(compact(response))"]
        }
        var lines: [String] = []
        var header = "\(outputLabel):"
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
        let reply = (dict["reply"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let reply { lines.append("  → text: \(reply)") }
        if let cli = dict["cli"] {
            lines.append("  cli: \(compact(removingDuplicateReply(cli, reply: reply)))")
        }
        if let runtime = dict["runtime"] {
            lines.append("  runtime: \(compact(removingDuplicateReply(runtime, reply: reply)))")
        }
        if let stderr = dict["stderr"] as? String, !stderr.isEmpty { lines.append("  stderr: \(stderr)") }
        // Usage is the quantitative core of the audit: `input_tokens_details.cached_tokens` vs
        // `input_tokens` is the prompt-cache hit rate, per call.
        if let usage = dict["usage"] { lines.append("  usage: \(compact(usage))") }
        if let error = dict["error"], !(error is NSNull) { lines.append("  API ERROR: \(compact(error))") }
        return lines
    }

    /// A fresh CLI attempt encodes its entire conversation as one growing text item. Item-level
    /// prefix elision therefore cannot help. Elide a substantial exact character prefix, preferably
    /// at a line boundary, and keep an explicit marker pointing to the untouched traffic source.
    private static func renderCLITextDelta(_ text: String, previous: String?, tag: String) -> String {
        guard let previous else { return text }
        var currentIndex = text.startIndex
        var previousIndex = previous.startIndex
        while currentIndex < text.endIndex,
              previousIndex < previous.endIndex,
              text[currentIndex] == previous[previousIndex] {
            text.formIndex(after: &currentIndex)
            previous.formIndex(after: &previousIndex)
        }
        let exactCount = text.distance(from: text.startIndex, to: currentIndex)
        guard exactCount >= 80, currentIndex < text.endIndex else { return text }

        let prefix = text[..<currentIndex]
        let lineBoundary = prefix.lastIndex(of: "\n").map { text.index(after: $0) }
        let safeEnd: String.Index
        if let lineBoundary,
           text.distance(from: text.startIndex, to: lineBoundary) >= 80 {
            safeEnd = lineBoundary
        } else if exactCount >= 256 {
            safeEnd = currentIndex
        } else {
            return text
        }
        let count = text.distance(from: text.startIndex, to: safeEnd)
        let marker = "[first \(count) chars unchanged from the previous \(tag) call within this CLI text item — full input remains in \(BrainTrafficLog.filename)]"
        return marker + "\n" + text[safeEnd...]
    }

    private static func cliText(_ item: Any) -> String? {
        guard let dict = item as? [String: Any],
              dict["type"] as? String == "text"
        else { return nil }
        return dict["text"] as? String
    }

    /// Codex's runtime envelope repeats `response.reply` inside `items`/`itemsView`. Preserve the
    /// envelope metadata but replace any exact duplicate string with an explicit one-line marker.
    private static func removingDuplicateReply(_ value: Any, reply: String?) -> Any {
        guard let reply else { return value }
        if let string = value as? String {
            return string == reply ? "[duplicate of response.reply omitted]" : string
        }
        if let array = value as? [Any] {
            return array.map { removingDuplicateReply($0, reply: reply) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { removingDuplicateReply($0, reply: reply) }
        }
        return value
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
