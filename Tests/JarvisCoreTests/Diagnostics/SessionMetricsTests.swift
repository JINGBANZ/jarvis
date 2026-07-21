import Testing
import Foundation
@testable import JarvisCore

@Suite struct SessionMetricsTests {
    /// One traffic line in the on-disk shape `BrainTrafficLog` writes.
    private func line(tag: String = "coach", status: Int? = 200, ms: Int = 500,
                      request: [String: Any], response: [String: Any]? = nil,
                      error: String? = nil) throws -> String {
        var entry: [String: Any] = ["t": "10:00:00", "tag": tag, "ms": ms, "request": request]
        entry["status"] = status
        entry["response"] = response
        entry["error"] = error
        return try #require(String(data: JSONSerialization.data(withJSONObject: entry), encoding: .utf8))
    }

    @Test func emptyTrafficRendersNothing() {
        #expect(SessionMetrics.render(jsonl: "") == "")
        #expect(SessionMetrics.render(jsonl: "not json\n{bad}") == "")
    }

    /// OpenAI Responses usage keeps an explicit zero distinct from unavailable telemetry and reads
    /// the newer cache-write field when the provider emits it. API cost remains unavailable.
    @Test func rendersOpenAIUsageAndTotals() throws {
        let first = try line(request: ["model": "gpt-5.5"],
                             response: ["usage": ["input_tokens": 100,
                                                  "input_tokens_details": ["cached_tokens": 40,
                                                                           "cache_write_tokens": 25],
                                                  "output_tokens": 12]])
        let second = try line(request: ["model": "gpt-5.5"],
                              response: ["usage": ["input_tokens": 200,
                                                   "input_tokens_details": ["cached_tokens": 0,
                                                                            "cache_write_tokens": 0],
                                                   "output_tokens": 20]])
        let out = SessionMetrics.render(jsonl: "\(first)\n\(second)")

        #expect(out.hasPrefix("=== deterministic metrics"))
        #expect(out.contains("| 1 | coach | gpt-5.5 | 200 | 500 | 100 | 40 | 25 | 12 | — |"))
        #expect(out.contains("| 2 | coach | gpt-5.5 | 200 | 500 | 200 | 0 | 0 | 20 | — |"))
        #expect(out.contains("session totals: 2 calls · input 300 · cache-read 40 · cache-write 25 · output 32 · cost —"))
    }

    @Test func rendersUnavailableOpenAICacheWriteAsUnknown() throws {
        let call = try line(request: ["model": "gpt-5.5"],
                            response: ["usage": ["input_tokens": 100,
                                                 "input_tokens_details": ["cached_tokens": 40],
                                                 "output_tokens": 12]])
        let out = SessionMetrics.render(jsonl: call)

        #expect(out.contains("| 1 | coach | gpt-5.5 | 200 | 500 | 100 | 40 | — | 12 | — |"))
        #expect(out.contains("session totals: 1 calls · input 100 · cache-read 40 · cache-write — · output 12 · cost —"))
    }

    /// A transport error has no response usage. The call happened, but every usage value is unknown.
    @Test func rendersTransportErrorCallWithUnknownUsage() throws {
        let failed = try line(status: nil, request: ["model": "gpt-5.5"], error: "timed out")
        let out = SessionMetrics.render(jsonl: failed)
        #expect(out.contains("| 1 | coach | gpt-5.5 | — | 500 | — | — | — | — | — |"))
        #expect(out.contains("session totals: 1 calls · input — · cache-read — · cache-write — · output — · cost —"))
        #expect(out.contains("| gpt-5.5 | 1 | — | — | — | — | — |"))
    }

    /// Local CLI (`claude -p`) envelope: cost from `total_cost_usd`, the Anthropic cache
    /// creation/read split from `cli.usage`, and per-model rows from `modelUsage` — including the
    /// internal sidecar (haiku) pass the call-level usage alone would hide.
    @Test func rendersCLIEnvelopeCostCacheSplitAndSidecarModels() throws {
        let cli: [String: Any] = [
            "total_cost_usd": 1.44,
            "usage": ["input_tokens": 4, "cache_creation_input_tokens": 12000,
                      "cache_read_input_tokens": 1285, "output_tokens": 200],
            "modelUsage": [
                "claude-opus-4-8": ["inputTokens": 4, "outputTokens": 200,
                                    "cacheReadInputTokens": 1285, "cacheCreationInputTokens": 12000,
                                    "costUSD": 1.40],
                "claude-haiku-4-5": ["inputTokens": 500, "outputTokens": 30,
                                     "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0,
                                     "costUSD": 0.04],
            ],
        ]
        let call = try line(ms: 900, request: ["model": "(CLI default)"],
                            response: ["exitCode": 0, "reply": "hi", "cli": cli])
        let out = SessionMetrics.render(jsonl: call)

        // Per-call: the cache creation/read split and the dollar cost, all from the CLI envelope.
        #expect(out.contains("| 1 | coach | (CLI default) | 200 | 900 | 4 | 1285 | 12000 | 200 | $1.4400 |"))
        #expect(out.contains("session totals: 1 calls · input 4 · cache-read 1285 · cache-write 12000 · output 200 · cost $1.4400"))
        // The per-model table breaks out both the main model and the sidecar haiku pass.
        #expect(out.contains("per-model totals"))
        #expect(out.contains("| claude-haiku-4-5 | 1 | 500 | 0 | 0 | 30 | $0.0400 |"))
        #expect(out.contains("| claude-opus-4-8 | 1 | 4 | 1285 | 12000 | 200 | $1.4000 |"))
    }

    /// Codex's recorded response has no usage envelope. Successful execution must not become a
    /// deterministic claim that the call consumed zero tokens and cost nothing.
    @Test func rendersCodexUsageAsUnavailable() throws {
        let call = try line(request: ["provider": "codex-cli", "model": "gpt-5.4"],
                            response: ["exitCode": 0, "reply": "hi"])
        let out = SessionMetrics.render(jsonl: call)

        #expect(out.contains("| 1 | coach | gpt-5.4 | 200 | 500 | — | — | — | — | — |"))
        #expect(out.contains("session totals: 1 calls · input — · cache-read — · cache-write — · output — · cost —"))
        #expect(out.contains("| gpt-5.4 | 1 | — | — | — | — | — |"))
    }

    /// Mixed providers get provider-specific token totals because OpenAI input includes cache hits
    /// while Anthropic reports uncached/cache-read/cache-write values separately. Known Claude cost
    /// remains explicitly partial instead of masquerading as the whole-session cost.
    @Test func separatesMixedProviderTokensAndLabelsPartialCost() throws {
        let openAI = try line(request: ["model": "gpt-5.5"],
                              response: ["usage": ["input_tokens": 100,
                                                   "input_tokens_details": ["cached_tokens": 40],
                                                   "output_tokens": 10]])
        let claude = try line(
            request: ["provider": "claude-code", "model": "opus"],
            response: ["cli": ["total_cost_usd": 1.5,
                                "usage": ["input_tokens": 2,
                                          "cache_read_input_tokens": 50,
                                          "cache_creation_input_tokens": 100,
                                          "output_tokens": 20]]])
        let out = SessionMetrics.render(jsonl: "\(openAI)\n\(claude)")

        #expect(out.contains("session totals: 2 calls · cost $1.5000 known (1 unavailable)"))
        #expect(out.contains("provider totals (token meanings differ; do not sum across providers)"))
        #expect(out.contains("| Claude Code | 1 | 2 | 50 | 100 | 20 | $1.5000 |"))
        #expect(out.contains("| OpenAI API | 1 | 100 | 40 | — | 10 | — |"))
        #expect(!out.contains("input 102"))
    }

    /// A field can be known for only part of a same-provider session. Preserve the known subtotal and
    /// state the unavailable-call count instead of either dropping it or presenting it as complete.
    @Test func labelsPartialSameProviderMetric() throws {
        let first = try line(request: ["model": "gpt-5.5"],
                             response: ["usage": ["input_tokens": 100,
                                                  "input_tokens_details": ["cached_tokens": 40,
                                                                           "cache_write_tokens": 25],
                                                  "output_tokens": 10]])
        let second = try line(request: ["model": "gpt-5.5"],
                              response: ["usage": ["input_tokens": 200,
                                                   "input_tokens_details": ["cached_tokens": 50],
                                                   "output_tokens": 20]])
        let out = SessionMetrics.render(jsonl: "\(first)\n\(second)")

        #expect(out.contains("cache-write 25 known (1 unavailable)"))
    }
}
