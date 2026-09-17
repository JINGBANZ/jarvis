import Foundation
import JarvisCore
import JarvisBrainProviders

/// Missing telemetry stays unavailable: never zero, and never dropped from a partial total.
enum SessionMetrics {
    /// `perModel` can include a CLI turn's sidecar models besides the requested one.
    struct Call {
        let number: Int
        let tag: String
        let provider: String
        let model: String
        let status: Int?
        let ms: Int?
        let recordKind: BrainTrafficAuditEvent.Kind
        var input: Int?
        var cacheRead: Int?
        var cacheWrite: Int?
        var output: Int?
        var cost: Double?
        var perModel: [String: ModelTotals] = [:]
    }

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

    /// Returns "" when there is no traffic, so callers' empty-transcript guards still fire. Record
    /// numbers match `EvaluationTranscript.render`.
    static func render(
        jsonl: String,
        auditEvidence: SessionAuditEvidence = .legacy
    ) -> String {
        let parsed = parseDetailed(jsonl: jsonl)
        guard parsed.totalRecords > 0 else { return "" }
        let calls = parsed.calls.filter { $0.recordKind == .providerCall }
        let preRequestFailures = parsed.calls.count(where: {
            $0.recordKind == .preRequestFailure
        })

        var lines: [String] = []
        lines.append(
            "=== provider-call telemetry (computed; descriptive, not diagnostic) ===")
        if parsed.malformedCount > 0 {
            lines.append("WARNING: \(parsed.malformedCount) malformed traffic record(s) could not be parsed; all session totals below are partial, not exact.")
        }
        if preRequestFailures > 0 {
            lines.append("CLI setup/pre-request failures: \(preRequestFailures) (excluded from provider-call and telemetry totals).")
        }
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
        if calls.isEmpty {
            if parsed.malformedCount > 0 {
                lines.append("session totals: 0 known provider calls (\(parsed.malformedCount) malformed record(s); total unavailable)")
            } else if auditEvidence.isPartial {
                lines.append("session totals: 0 known provider calls (total unavailable)")
            } else {
                lines.append("session totals: 0 provider calls")
            }
            return lines.joined(separator: "\n")
        }
        let providers = Dictionary(grouping: calls, by: \.provider)
        let callCount: String
        if parsed.malformedCount > 0 {
            callCount = "\(calls.count) known calls (\(parsed.malformedCount) malformed record(s); total unavailable)"
        } else if auditEvidence.isPartial {
            callCount = "\(calls.count) known calls (session total unavailable)"
        } else {
            callCount = "\(calls.count) calls"
        }
        let totalsLabel = auditEvidence.isPartial ? "known recorded totals" : "session totals"
        if providers.count == 1 {
            lines.append("\(totalsLabel): \(callCount) · \(totals(calls))")
        } else {
            // OpenAI input includes cached input while Anthropic reports it separately, so never
            // sum tokens across providers.
            lines.append("\(totalsLabel): \(callCount) · cost \(totalMoney(calls, \.cost))")
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

    /// Record numbers keep gaps for malformed lines, so they stay stable anchors into the file.
    static func parse(jsonl: String) -> [Call] {
        parseDetailed(jsonl: jsonl).calls
    }

    private struct ParsedCalls {
        let calls: [Call]
        let malformedCount: Int
        let totalRecords: Int
    }

    private static func parseDetailed(jsonl: String) -> ParsedCalls {
        var calls: [Call] = []
        let records = JSONLRecords.parse(jsonl)
        for record in records.lines {
            guard let entry = record.object else { continue }
            let request = entry["request"] as? [String: Any]
            let response = entry["response"] as? [String: Any]
            let model = request?["model"] as? String ?? "?"
            let recordKind = (entry["record_kind"] as? String)
                .flatMap(BrainTrafficAuditEvent.Kind.init(rawValue:)) ?? .providerCall
            var call = Call(number: record.number,
                            tag: entry["tag"] as? String ?? "?",
                            provider: providerName(
                                provider: entry["provider"] as? String, request: request, response: response),
                            model: model,
                            status: entry["status"] as? Int,
                            ms: entry["ms"] as? Int,
                            recordKind: recordKind)

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
            } else if request?["runtime"] as? String == "one-shot-exec",
                      let usage = (response?["runtime"] as? [String: Any])?["usage"]
                        as? [String: Any] {
                // Keyed on the transport: both Codex transports write `response.runtime`, but only
                // `codex exec` spells usage this way. `input_tokens` includes cached input.
                call.input = int(usage["input_tokens"])
                call.cacheRead = int(usage["cached_input_tokens"])
                call.cacheWrite = int(usage["cache_write_input_tokens"])
                call.output = int(usage["output_tokens"])
                call.perModel[model] = ModelTotals(input: call.input, cacheRead: call.cacheRead,
                                                   cacheWrite: call.cacheWrite, output: call.output,
                                                   cost: nil, calls: 1)
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
                // No usage envelope: keep the model listed, with its values unavailable.
                call.perModel[model] = ModelTotals(input: call.input, cacheRead: call.cacheRead,
                                                   cacheWrite: call.cacheWrite, output: call.output,
                                                   cost: call.cost, calls: 1)
            }
            calls.append(call)
        }
        return ParsedCalls(
            calls: calls,
            malformedCount: records.malformedCount,
            totalRecords: records.lines.count)
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

    private static func money(_ value: Double?) -> String {
        value.map { String(format: "$%.4f", $0) } ?? "—"
    }

    /// The CLI envelope mixes camelCase (`modelUsage`) and snake_case (`usage`) keys.
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

    /// Older records name a CLI provider inside `request` instead, and none at all for OpenAI.
    static func providerName(
        provider: String?, request: [String: Any]?, response: [String: Any]?
    ) -> String {
        switch provider ?? (request?["provider"] as? String) {
        case .some(let raw):
            if let known = BrainProvider(rawValue: raw) { return known.displayName }
            switch raw {
            case "claude-code": return "Claude Code"
            case "codex-cli": return "Codex CLI"
            default: return raw
            }
        case nil:
            return response?["cli"] == nil ? BrainProvider.openAI.displayName : "Claude Code"
        }
    }
}
