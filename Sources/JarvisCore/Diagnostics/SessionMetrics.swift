import Foundation

/// Deterministic, pure-Swift accounting of a session's brain traffic: per-call and aggregate token /
/// cache / cost numbers computed straight from `brain-traffic.jsonl` and rendered as a table that
/// leads the evaluation transcript (see `EvaluationTranscript.render`). Missing telemetry stays
/// unavailable — it is never silently converted to a factual zero or omitted from a partial total.
///
/// Why this exists: the auditor is an LLM, and the 2026-07-19 session audit's factual slips (total
/// cost off by $0.20, a "cache_creation climbs monotonically" claim that actually zigzagged) all came
/// from a model doing arithmetic over ~20 JSON usage blobs *by eye*. So we compute the numbers here,
/// once, correctly, and tell the model to interpret them and never recompute totals itself.
///
/// Provider records are handled separately because the same session file can mix them:
///   - **OpenAI Responses** — `response.usage`: `input_tokens`, `input_tokens_details.cached_tokens`
///     (the automatic prefix-cache hit), optional `cache_write_tokens`, and `output_tokens`
///     (reasoning tokens included). No per-call dollar cost is recorded, so cost renders as "—".
///   - **Local CLI** (`claude -p`, `CLIBrainClient`) — `response.cli`: `total_cost_usd`, a call-level
///     `usage` with Anthropic's `cache_creation_input_tokens` / `cache_read_input_tokens` split, and
///     a `modelUsage` map that breaks usage + cost out per model — including the CLI's own internal
///     sidecar models (e.g. its haiku pass), which the call-level `usage` alone would hide.
///   - **Codex CLI** — the response record has no token, cache, or cost usage, so those values remain
///     unavailable rather than becoming zero.
enum SessionMetrics {
    /// One row of the per-call table. `perModel` attributes this call's usage to the concrete
    /// model(s) that served it (a CLI turn can touch a main model plus a sidecar).
    struct Call {
        let number: Int
        let tag: String
        let provider: String
        let model: String
        let status: Int?
        let ms: Int?
        var input: Int?
        var cacheRead: Int?
        var cacheWrite: Int?
        var output: Int?
        var cost: Double?
        var perModel: [String: ModelTotals] = [:]
    }

    /// Accumulated usage for one model, across one or many calls.
    struct ModelTotals {
        var input: Int?
        var cacheRead: Int?
        var cacheWrite: Int?
        var output: Int?
        var cost: Double?
        var calls = 0

        mutating func add(_ other: ModelTotals) {
            guard calls > 0 else {
                self = other
                return
            }
            input = SessionMetrics.combined(input, other.input)
            cacheRead = SessionMetrics.combined(cacheRead, other.cacheRead)
            cacheWrite = SessionMetrics.combined(cacheWrite, other.cacheWrite)
            output = SessionMetrics.combined(output, other.output)
            cost = SessionMetrics.combined(cost, other.cost)
            calls += other.calls
        }
    }

    // MARK: - Rendering

    /// The metrics block that leads the transcript, or "" when there is no traffic (so callers'
    /// empty-transcript guards still fire). Call numbering matches `EvaluationTranscript.render`
    /// exactly — both count one call per JSON-parseable line, in file order.
    static func render(jsonl: String) -> String {
        let calls = parse(jsonl: jsonl)
        guard !calls.isEmpty else { return "" }

        var lines: [String] = []
        lines.append(
            "=== deterministic metrics (computed from \(BrainTrafficLog.filename); interpret these — do NOT recompute totals by eye) ===")
        lines.append("")
        lines.append("| call | tag | provider | model | HTTP | ms | input | cache read | cache write | output | cost |")
        lines.append("|--:|---|---|---|--:|--:|--:|--:|--:|--:|--:|")
        for c in calls {
            lines.append("| \(c.number) | \(c.tag) | \(c.provider) | \(c.model) "
                + "| \(c.status.map(String.init) ?? "—") "
                + "| \(c.ms.map(String.init) ?? "—") | \(number(c.input)) | \(number(c.cacheRead)) "
                + "| \(number(c.cacheWrite)) | \(number(c.output)) | \(money(c.cost)) |")
        }

        lines.append("")
        let providers = Dictionary(grouping: calls, by: \.provider)
        if providers.count == 1 {
            lines.append("session totals: \(calls.count) calls · \(totals(calls))")
        } else {
            // OpenAI input includes cached input while Anthropic reports uncached input separately.
            // Do not manufacture a cross-provider token total from fields with different semantics.
            lines.append("session totals: \(calls.count) calls · cost \(totalMoney(calls, \.cost))")
            lines.append("")
            lines.append("provider totals (token meanings differ; do not sum across providers):")
            lines.append("| provider | calls | input | cache read | cache write | output | cost |")
            lines.append("|---|--:|--:|--:|--:|--:|--:|")
            for provider in providers.keys.sorted() {
                let providerCalls = providers[provider]!
                lines.append("| \(provider) | \(providerCalls.count) | \(totalNumber(providerCalls, \.input)) "
                    + "| \(totalNumber(providerCalls, \.cacheRead)) "
                    + "| \(totalNumber(providerCalls, \.cacheWrite)) "
                    + "| \(totalNumber(providerCalls, \.output)) "
                    + "| \(totalMoney(providerCalls, \.cost)) |")
            }
        }

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
                lines.append("| \(name) | \(t.calls) | \(number(t.input)) | \(number(t.cacheRead)) "
                    + "| \(number(t.cacheWrite)) | \(number(t.output)) | \(money(t.cost)) |")
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
            let response = entry["response"] as? [String: Any]
            let model = request?["model"] as? String ?? "?"
            var call = Call(number: number,
                            tag: entry["tag"] as? String ?? "?",
                            provider: providerName(request: request, response: response),
                            model: model,
                            status: entry["status"] as? Int,
                            ms: entry["ms"] as? Int)

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
                let details = usage["input_tokens_details"] as? [String: Any]
                call.cacheRead = int(details?["cached_tokens"])
                call.cacheWrite = int(details?["cache_write_tokens"])
                call.output = int(usage["output_tokens"])
                call.perModel[model] = ModelTotals(input: call.input, cacheRead: call.cacheRead,
                                                   cacheWrite: call.cacheWrite, output: call.output,
                                                   cost: nil, calls: 1)
            }
            if call.perModel.isEmpty {
                // Errors and Codex calls have no usage envelope. Keep the requested model visible in
                // the per-model table, but propagate unavailable values through any later aggregate.
                call.perModel[model] = ModelTotals(input: call.input, cacheRead: call.cacheRead,
                                                   cacheWrite: call.cacheWrite, output: call.output,
                                                   cost: call.cost, calls: 1)
            }
            calls.append(call)
        }
        return calls
    }

    // MARK: - Small helpers

    private static func totals(_ calls: [Call]) -> String {
        "input \(totalNumber(calls, \.input)) · cache-read \(totalNumber(calls, \.cacheRead)) "
            + "· cache-write \(totalNumber(calls, \.cacheWrite)) "
            + "· output \(totalNumber(calls, \.output)) · cost \(totalMoney(calls, \.cost))"
    }

    private static func totalNumber(_ calls: [Call], _ key: KeyPath<Call, Int?>) -> String {
        let known = calls.compactMap { $0[keyPath: key] }
        return availability(String(known.reduce(0, +)), known: known.count, total: calls.count)
    }

    private static func totalMoney(_ calls: [Call], _ key: KeyPath<Call, Double?>) -> String {
        let known = calls.compactMap { $0[keyPath: key] }
        let rendered = String(format: "$%.4f", known.reduce(0, +))
        return availability(rendered, known: known.count, total: calls.count)
    }

    private static func availability(_ value: String, known: Int, total: Int) -> String {
        guard known > 0 else { return "—" }
        let unavailable = total - known
        return unavailable == 0 ? value : "\(value) known (\(unavailable) unavailable)"
    }

    private static func number(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }

    /// Format a dollar amount to 4 dp, or "—" when no cost was recorded.
    private static func money(_ value: Double?) -> String {
        value.map { String(format: "$%.4f", $0) } ?? "—"
    }

    /// First non-nil value among the given keys — lets one reader handle both camelCase (`modelUsage`)
    /// and snake_case (`usage`) spellings the CLI envelope mixes.
    private static func first(_ dict: [String: Any], _ keys: String...) -> Any? {
        for key in keys where dict[key] != nil { return dict[key] }
        return nil
    }

    private static func int(_ any: Any?) -> Int? {
        (any as? NSNumber)?.intValue
    }

    private static func double(_ any: Any?) -> Double? {
        (any as? NSNumber)?.doubleValue
    }

    private static func combined(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }

    private static func combined(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }

    static func providerName(request: [String: Any]?, response: [String: Any]?) -> String {
        switch request?["provider"] as? String {
        case BrainProvider.claudeCode.rawValue: return BrainProvider.claudeCode.displayName
        case BrainProvider.codexCLI.rawValue: return BrainProvider.codexCLI.displayName
        case BrainProvider.openAI.rawValue: return BrainProvider.openAI.displayName
        case .some(let provider): return provider
        case nil:
            // Direct OpenAI requests are the wire body itself and do not carry Jarvis's provider key.
            return response?["cli"] == nil ? BrainProvider.openAI.displayName
                                           : BrainProvider.claudeCode.displayName
        }
    }
}
