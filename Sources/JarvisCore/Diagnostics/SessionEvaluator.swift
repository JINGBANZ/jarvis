import Foundation

/// One-click session evaluation: turns a session's recorded brain traffic (`brain-traffic.jsonl`,
/// see `BrainTrafficLog`) into a readable wire transcript, sends it to an LLM with an audit prompt
/// focused on context engineering, and saves the returned report as `eval-report.md` in the session
/// directory. This automates the old manual loop of pulling request logs from the OpenAI dashboard
/// and pasting them into a chat for diagnosis.
///
/// The transcript rendering is deliberately delta-aware: the harness rebuilds every request as
/// `[system] + history + turn` with an append-only prefix, so consecutive requests repeat almost all
/// of their `input`. Re-sending those repeats to the evaluator would bury the signal (and cost real
/// tokens), so unchanged instructions/tools/input prefixes are elided and *marked as elided* — the
/// elision markers themselves tell the evaluator the prompt cache should be hitting there.
public struct SessionEvaluator: Sendable {
    public static let reportFilename = "eval-report.md"

    private let brain: BrainClient

    public init(brain: BrainClient) {
        self.brain = brain
    }

    public enum EvaluationError: LocalizedError, Equatable {
        case noTraffic
        case emptyReport
        public var errorDescription: String? {
            switch self {
            case .noTraffic:
                return "No brain traffic was recorded for this session — nothing to evaluate."
            case .emptyReport:
                return "The evaluation model returned an empty report."
            }
        }
    }

    /// Whether a session has anything to evaluate (a non-empty traffic file).
    public static func hasTraffic(in sessionDir: URL) -> Bool {
        let url = sessionDir.appendingPathComponent(BrainTrafficLog.filename)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
        return (size?.intValue ?? 0) > 0
    }

    /// Evaluate one session: render its traffic, ask the brain for the audit, persist and return the
    /// markdown report. The report is written owner-only next to the traffic it audits, so it survives
    /// for later browsing and re-reading without re-billing an evaluation.
    public func evaluate(sessionDir: URL) async throws -> String {
        let url = sessionDir.appendingPathComponent(BrainTrafficLog.filename)
        let jsonl = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let transcript = Self.renderTranscript(jsonl: jsonl)
        guard !transcript.isEmpty else { throw EvaluationError.noTraffic }

        let response = try await brain.respond(
            messages: [.system(Self.evalInstructions), .user(transcript)],
            tools: [], toolChoice: .auto)
        guard let report = response.outputText, !report.isEmpty else {
            throw EvaluationError.emptyReport
        }
        FileManager.default.createFile(
            atPath: sessionDir.appendingPathComponent(Self.reportFilename).path,
            contents: Data(report.utf8), attributes: [.posixPermissions: 0o600])
        return report
    }

    // MARK: - Transcript rendering (pure, testable)

    /// Render the recorded traffic as a readable transcript, one block per round trip, eliding
    /// request content that is byte-identical to the previous call with the same tag (see the type
    /// comment). Malformed lines are skipped; an empty/blank file renders as "".
    static func renderTranscript(jsonl: String) -> String {
        var blocks: [String] = []
        // Elision state, per tag (coach and summarizer interleave but never share a prefix).
        var prevInstructions: [String: String] = [:]
        var prevTools: [String: String] = [:]
        var prevInput: [String: [String]] = [:]
        var callNumber = 0

        for raw in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            else { continue }
            callNumber += 1
            let tag = entry["tag"] as? String ?? "?"
            var lines: [String] = []

            var header = "=== call #\(callNumber) · \(tag) · \(entry["t"] as? String ?? "?")"
            if let status = entry["status"] as? Int { header += " · HTTP \(status)" }
            if let ms = entry["ms"] as? Int { header += " · \(ms) ms" }
            lines.append(header)
            if let error = entry["error"] as? String { lines.append("TRANSPORT ERROR: \(error)") }

            if let request = entry["request"] as? [String: Any] {
                lines.append(contentsOf: renderRequest(request, tag: tag,
                                                       prevInstructions: &prevInstructions,
                                                       prevTools: &prevTools,
                                                       prevInput: &prevInput))
            }
            if let response = entry["response"] {
                lines.append(contentsOf: renderResponse(response))
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func renderRequest(_ request: [String: Any], tag: String,
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
        if instructions == prevInstructions[tag] {
            lines.append("instructions: (unchanged — \(instructions.count) chars)")
        } else if !instructions.isEmpty {
            lines.append("instructions (\(instructions.count) chars):\n\(instructions)")
        }
        prevInstructions[tag] = instructions

        let tools = canonical(request["tools"] ?? [])
        if tools == prevTools[tag] {
            let count = (request["tools"] as? [Any])?.count ?? 0
            lines.append("tools: (unchanged — \(count) defs)")
        } else {
            lines.append("tools: \(tools)")
        }
        prevTools[tag] = tools

        let items = request["input"] as? [Any] ?? []
        let rendered = items.map { renderInputItem($0) }
        let canon = items.map { canonical($0) }
        let prev = prevInput[tag] ?? []
        var shared = 0
        while shared < min(canon.count, prev.count), canon[shared] == prev[shared] { shared += 1 }
        lines.append("input (\(items.count) items):")
        if shared > 0 {
            lines.append("  [items 1–\(shared) unchanged from the previous \(tag) call — the stable, cacheable prefix]")
        }
        lines.append(contentsOf: rendered.dropFirst(shared).map { "  \($0)" })
        prevInput[tag] = canon
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

    // MARK: - The audit prompt

    static let evalInstructions = """
    You are auditing one session of Jarvis, a proactive macOS coaching assistant: it transcribes \
    the user's (and their interlocutor's) speech, optionally screenshots the user's screen, and an \
    LLM decides each turn to speak a short overlay tip, look at the screen, or stay silent. The \
    session's memory is client-managed: each request is [instructions] + history + new turn, built \
    append-only so the provider's prompt cache keeps hitting; old history is periodically compacted \
    into a summary by a separate "summarizer" client.

    The user message is the session's complete wire-level LLM traffic, one block per API call, in \
    order. To keep it compact: content that is byte-identical to the previous call with the same tag \
    is elided and explicitly marked "(unchanged)" — those markers are where the prompt cache SHOULD \
    be hitting; base64 screenshots are redacted to a stub. Each response block includes the raw \
    usage object (input_tokens_details.cached_tokens vs input_tokens is the cache hit rate).

    Write a markdown report with exactly these sections:

    ## Context engineering
    Inefficiencies in what the harness sends: cache-busting prefix changes (input marked as changed \
    that should have been stable), redundant or stale content re-billed every call, oversized \
    instructions or tool schemas relative to their value, history-compaction timing/quality, \
    screenshots kept or stubbed at the wrong time. Be quantitative with the usage numbers.

    ## Issues and errors
    Transport errors, non-2xx responses, truncated runs (status=incomplete), tool-loop anomalies \
    (repeated capture_screen, exhausted loops), and any contradiction between the instructions and \
    the model's behavior.

    ## Coaching quality
    Given the transcript deltas the model saw: tips that were wrong, late, redundant, or noisy; \
    silences that should have been tips and vice versa.

    ## Recommendations
    Concrete changes, ordered by expected impact, each tied to evidence above.

    Cite call numbers (call #N) as evidence throughout. If the data doesn't support a finding, say \
    so rather than speculating.
    """
}
