import Foundation

/// Deterministic, pure-Swift accounting of a session's brain traffic: per-call and session-total
/// token / cache / cost numbers computed straight from `brain-traffic.jsonl` and rendered as a table
/// that leads the evaluation transcript (see `SessionEvaluator.renderTranscript`).
///
/// Why this exists: the auditor is an LLM, and the 2026-07-19 session audit's factual slips (total
/// cost off by $0.20, a "cache_creation climbs monotonically" claim that actually zigzagged) all came
/// from a model doing arithmetic over ~20 JSON usage blobs *by eye*. So we compute the numbers here,
/// once, correctly, and tell the model to interpret them and never recompute totals itself.
///
/// Both provider envelopes are handled, because the same session file can mix them:
///   - **OpenAI Responses** — `response.usage`: `input_tokens`, `input_tokens_details.cached_tokens`
///     (the automatic prefix-cache hit), `output_tokens` (reasoning tokens included). No per-call
///     dollar cost is recorded, so cost renders as "—".
///   - **Local CLI** (`claude -p`, `CLIBrainClient`) — `response.cli`: `total_cost_usd`, a call-level
///     `usage` with Anthropic's `cache_creation_input_tokens` / `cache_read_input_tokens` split, and
///     a `modelUsage` map that breaks usage + cost out per model — including the CLI's own internal
///     sidecar models (e.g. its haiku pass), which the call-level `usage` alone would hide.
enum SessionMetrics {
    /// One row of the per-call table. `perModel` attributes this call's usage to the concrete
    /// model(s) that served it (a CLI turn can touch a main model plus a sidecar).
    struct Call {
        let number: Int
        let tag: String
        let model: String
        let status: Int?
        let ms: Int?
        var input = 0
        var cacheRead = 0
        var cacheWrite = 0
        var output = 0
        var cost: Double?
        var perModel: [String: ModelTotals] = [:]
    }

    /// Accumulated usage for one model, across one or many calls.
    struct ModelTotals {
        var input = 0
        var cacheRead = 0
        var cacheWrite = 0
        var output = 0
        var cost: Double?
        var calls = 0

        mutating func add(_ other: ModelTotals) {
            input += other.input
            cacheRead += other.cacheRead
            cacheWrite += other.cacheWrite
            output += other.output
            calls += other.calls
            if let c = other.cost { cost = (cost ?? 0) + c }
        }
    }

    // MARK: - Rendering

    /// The metrics block that leads the transcript, or "" when there is no traffic (so callers'
    /// empty-transcript guards still fire). Call numbering matches `SessionEvaluator.renderTranscript`
    /// exactly — both count one call per JSON-parseable line, in file order.
    static func render(jsonl: String) -> String {
        let calls = parse(jsonl: jsonl)
        guard !calls.isEmpty else { return "" }

        var lines: [String] = []
        lines.append(
            "=== deterministic metrics (computed from \(BrainTrafficLog.filename); interpret these — do NOT recompute totals by eye) ===")
        lines.append("")
        lines.append("| call | tag | model | HTTP | ms | input | cache read | cache write | output | cost |")
        lines.append("|--:|---|---|--:|--:|--:|--:|--:|--:|--:|")
        for c in calls {
            lines.append("| \(c.number) | \(c.tag) | \(c.model) | \(c.status.map(String.init) ?? "—") "
                + "| \(c.ms.map(String.init) ?? "—") | \(c.input) | \(c.cacheRead) | \(c.cacheWrite) "
                + "| \(c.output) | \(money(c.cost)) |")
        }

        let costs = calls.compactMap(\.cost)
        let costTotal = costs.isEmpty ? nil : costs.reduce(0, +)
        lines.append("")
        lines.append("session totals: \(calls.count) calls · input \(sum(calls, \.input)) "
            + "· cache-read \(sum(calls, \.cacheRead)) · cache-write \(sum(calls, \.cacheWrite)) "
            + "· output \(sum(calls, \.output)) · cost \(money(costTotal))")

        var perModel: [String: ModelTotals] = [:]
        for c in calls {
            for (name, totals) in c.perModel { perModel[name, default: ModelTotals()].add(totals) }
        }
        if !perModel.isEmpty {
            lines.append("")
            lines.append("per-model totals (includes provider-internal sidecar models):")
            lines.append("| model | calls | input | cache read | cache write | output | cost |")
            lines.append("|---|--:|--:|--:|--:|--:|--:|")
            for name in perModel.keys.sorted() {
                let t = perModel[name]!
                lines.append("| \(name) | \(t.calls) | \(t.input) | \(t.cacheRead) | \(t.cacheWrite) "
                    + "| \(t.output) | \(money(t.cost)) |")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing (pure)

    /// Parse every JSON-parseable line into a `Call`. Malformed lines are skipped but still advance
    /// nothing (they aren't counted), so numbering stays aligned with the rendered transcript.
    static func parse(jsonl: String) -> [Call] {
        var calls: [Call] = []
        var number = 0
        for raw in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            else { continue }
            number += 1
            let request = entry["request"] as? [String: Any]
            let model = request?["model"] as? String ?? "?"
            var call = Call(number: number,
                            tag: entry["tag"] as? String ?? "?",
                            model: model,
                            status: entry["status"] as? Int,
                            ms: entry["ms"] as? Int)
            let response = entry["response"] as? [String: Any]

            if let cli = response?["cli"] as? [String: Any] {
                call.cost = double(cli["total_cost_usd"])
                if let usage = cli["usage"] as? [String: Any] {
                    call.input = int(usage["input_tokens"])
                    call.cacheRead = int(usage["cache_read_input_tokens"])
                    call.cacheWrite = int(usage["cache_creation_input_tokens"])
                    call.output = int(usage["output_tokens"])
                }
                if let modelUsage = cli["modelUsage"] as? [String: Any], !modelUsage.isEmpty {
                    for (name, value) in modelUsage {
                        guard let d = value as? [String: Any] else { continue }
                        call.perModel[name] = ModelTotals(
                            input: int(first(d, "inputTokens", "input_tokens")),
                            cacheRead: int(first(d, "cacheReadInputTokens", "cache_read_input_tokens")),
                            cacheWrite: int(first(d, "cacheCreationInputTokens", "cache_creation_input_tokens")),
                            output: int(first(d, "outputTokens", "output_tokens")),
                            cost: double(first(d, "costUSD", "cost_usd")),
                            calls: 1)
                    }
                } else {
                    call.perModel[model] = ModelTotals(input: call.input, cacheRead: call.cacheRead,
                                                       cacheWrite: call.cacheWrite, output: call.output,
                                                       cost: call.cost, calls: 1)
                }
            } else if let usage = response?["usage"] as? [String: Any] {
                call.input = int(usage["input_tokens"])
                call.cacheRead = int((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"])
                call.output = int(usage["output_tokens"])
                call.perModel[model] = ModelTotals(input: call.input, cacheRead: call.cacheRead,
                                                   cacheWrite: 0, output: call.output,
                                                   cost: nil, calls: 1)
            }
            calls.append(call)
        }
        return calls
    }

    // MARK: - Small helpers

    private static func sum(_ calls: [Call], _ key: KeyPath<Call, Int>) -> Int {
        calls.reduce(0) { $0 + $1[keyPath: key] }
    }

    /// Format a dollar amount to 4 dp, or "—" when no cost was recorded (OpenAI never records one).
    private static func money(_ value: Double?) -> String {
        value.map { String(format: "$%.4f", $0) } ?? "—"
    }

    /// First non-nil value among the given keys — lets one reader handle both camelCase (`modelUsage`)
    /// and snake_case (`usage`) spellings the CLI envelope mixes.
    private static func first(_ dict: [String: Any], _ keys: String...) -> Any? {
        for key in keys where dict[key] != nil { return dict[key] }
        return nil
    }

    private static func int(_ any: Any?) -> Int {
        (any as? NSNumber)?.intValue ?? 0
    }

    private static func double(_ any: Any?) -> Double? {
        (any as? NSNumber)?.doubleValue
    }
}
