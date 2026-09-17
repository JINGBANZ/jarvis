import Foundation
import JarvisBrainProviders
import JarvisCore

/// Request content unchanged since the previous call on the same stream is elided with a marker;
/// the agent still has the full `brain-traffic.jsonl`.
enum EvaluationTranscript {

    /// An empty or blank file renders as "".
    static func render(
        jsonl: String,
        attemptsJSONL: String? = nil,
        activityJSONL: String? = nil,
        healthJSON: String? = nil
    ) -> String {
        var blocks: [String] = []
        var prevInstructions: [String: String] = [:]
        var prevTools: [String: String] = [:]
        var prevInput: [String: [String]] = [:]
        var prevInputText: [String: [String?]] = [:]
        let records = JSONLRecords.parse(jsonl)
        for record in records.lines {
            guard let entry = record.object else {
                blocks.append(
                    "=== record #\(record.number) · malformed traffic entry · evidence unavailable; inspect \(FileSessionAudit.brainTrafficFilename) ===")
                continue
            }
            let callNumber = record.number
            let tag = entry["tag"] as? String ?? "?"
            let request = entry["request"] as? [String: Any]
            let response = entry["response"] as? [String: Any]
            let exchange = RecordedExchange.read(
                provider: entry["provider"] as? String ?? request?["provider"] as? String,
                request: entry["request"], response: entry["response"])
            let provider = SessionMetrics.providerName(
                provider: entry["provider"] as? String, request: request, response: response)
            let isPreRequestFailure = entry["record_kind"] as? String
                == BrainTrafficAuditEvent.Kind.preRequestFailure.rawValue
            // A failover keeps the tag, so elision state is keyed by provider and model too.
            let model = exchange.model ?? "?"
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

            if request != nil {
                lines.append(contentsOf: renderRequest(exchange, tag: tag, streamKey: streamKey,
                                                       prevInstructions: &prevInstructions,
                                                       prevTools: &prevTools,
                                                       prevInput: &prevInput,
                                                       prevInputText: &prevInputText))
            }
            if let response = entry["response"] {
                lines.append(contentsOf: renderResponse(response, exchange: exchange, tag: tag))
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        guard !blocks.isEmpty else { return "" }
        let body = blocks.joined(separator: "\n\n")
        let auditEvidence = SessionAuditEvidence.assess(
            trafficJSONL: jsonl,
            attemptsJSONL: attemptsJSONL,
            healthJSON: healthJSON)
        let evidenceIndex = SessionEvidenceIndex.render(
            trafficJSONL: jsonl,
            attemptsJSONL: attemptsJSONL,
            activityJSONL: activityJSONL,
            healthJSON: healthJSON,
            auditEvidence: auditEvidence)
        return evidenceIndex + "\n\n"
            + SessionMetrics.render(jsonl: jsonl, auditEvidence: auditEvidence)
            + "\n\n" + body
    }

    private static func renderRequest(_ exchange: RecordedExchange, tag: String, streamKey: String,
                                      prevInstructions: inout [String: String],
                                      prevTools: inout [String: String],
                                      prevInput: inout [String: [String]],
                                      prevInputText: inout [String: [String?]]) -> [String] {
        var lines: [String] = []
        var params = "request: model=\(exchange.model ?? "?")"
        for parameter in exchange.parameters { params += " \(parameter.name)=\(parameter.value)" }
        lines.append(params)

        let instructions = exchange.instructions ?? ""
        if instructions == prevInstructions[streamKey] {
            lines.append("instructions: (unchanged — \(instructions.count) chars)")
        } else if !instructions.isEmpty {
            lines.append("instructions (\(instructions.count) chars):\n\(instructions)")
        }
        prevInstructions[streamKey] = instructions

        let tools = exchange.toolsFingerprint
        if tools == prevTools[streamKey] {
            lines.append("tools: (unchanged — \(exchange.toolCount) defs)")
        } else {
            lines.append("tools: \(tools)")
        }
        prevTools[streamKey] = tools

        let items = exchange.input
        let canon = exchange.inputFingerprints
        let prev = prevInput[streamKey] ?? []
        let previousText = prevInputText[streamKey] ?? []
        let currentText = items.map { item -> String? in
            if case .text(let text) = item { text } else { nil }
        }
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

    private static func renderInputItem(
        _ item: RecordedExchange.InputItem, previousCLIText: String?, tag: String
    ) -> String {
        switch item {
        case .message(let role, let parts):
            return "\(role): \(parts.joined(separator: "\n"))"
        case .call(let call):
            return "assistant → function_call \(call.name ?? "?")(\(call.arguments ?? ""))"
        case .result(_, let output):
            return "tool result: \(output ?? "")"
        case .reasoning(let characters):
            // Replayed verbatim with a possibly large opaque blob and no audit signal.
            return "assistant reasoning (replayed verbatim — \(characters) chars)"
        // Older CLI-provider records: plain content blocks, images already stubbed.
        case .text(let text):
            return "text: " + renderCLITextDelta(text ?? "", previous: previousCLIText, tag: tag)
        case .image(let image):
            return "image: \(image ?? "(redacted)")"
        case .other(let json):
            return json
        }
    }

    private static func renderResponse(_ response: Any, exchange: RecordedExchange, tag: String) -> [String] {
        let outputLabel = tag == "coach" ? "Jarvis brain output" : "\(tag) brain output"
        guard let dict = response as? [String: Any] else {
            return ["\(outputLabel) (unparsed): \(compact(response))"]
        }
        var lines: [String] = []
        var header = "\(outputLabel):"
        if let status = exchange.status { header += " status=\(status)" }
        if let details = exchange.incompleteDetail { header += " incomplete_details=\(details)" }
        if let exit = dict["exitCode"] as? Int { header += " exit=\(exit)" }   // CLI-provider record
        lines.append(header)
        for output in exchange.outputs {
            switch output {
            case .call(let call):
                lines.append("  → function_call \(call.name ?? "?")(\(call.arguments ?? ""))")
            case .text(let text):
                lines.append("  → text: \(text)")
            case .reasoning:
                continue   // encrypted/empty reasoning stubs carry no signal
            case .other(let json):
                lines.append("  → \(json)")
            }
        }
        // CLI-provider records carry the reply as one string instead of an `output` array.
        let reply = (dict["reply"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let reply { lines.append("  → text: \(reply)") }
        if let cli = dict["cli"] {
            lines.append("  cli: \(compact(removingDuplicateReply(cli, reply: reply)))")
        }
        if let runtime = dict["runtime"] {
            lines.append("  runtime: \(compact(removingDuplicateReply(runtime, reply: reply)))")
        }
        if let stderr = dict["stderr"] as? String, !stderr.isEmpty { lines.append("  stderr: \(stderr)") }
        if let usage = exchange.usage { lines.append("  usage: \(usage.rendered)") }
        if let error = dict["error"], !(error is NSNull) { lines.append("  API ERROR: \(compact(error))") }
        return lines
    }

    /// A CLI attempt sends its whole conversation as one growing text item, so item-level elision
    /// can't help; elide a shared character prefix instead.
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
        let marker = "[first \(count) chars unchanged from the previous \(tag) call within this CLI text item — full input remains in \(FileSessionAudit.brainTrafficFilename)]"
        return marker + "\n" + text[safeEnd...]
    }

    /// Codex's runtime envelope repeats `response.reply` inside `items`/`itemsView`.
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

    private static func canonical(_ value: Any) -> String {
        RecordedExchange.canonical(value)
    }

    private static func compact(_ value: Any) -> String { canonical(value) }
}
