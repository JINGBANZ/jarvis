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

    /// OpenAI Responses usage: cached_tokens is the cache read, there is no cache write, and cost is
    /// unknown (renders as "—"). Session totals sum across calls.
    @Test func rendersOpenAIUsageAndTotals() throws {
        let first = try line(request: ["model": "gpt-5.5"],
                             response: ["usage": ["input_tokens": 100,
                                                  "input_tokens_details": ["cached_tokens": 40],
                                                  "output_tokens": 12]])
        let second = try line(request: ["model": "gpt-5.5"],
                              response: ["usage": ["input_tokens": 200,
                                                   "input_tokens_details": ["cached_tokens": 150],
                                                   "output_tokens": 20]])
        let out = SessionMetrics.render(jsonl: "\(first)\n\(second)")

        #expect(out.hasPrefix("=== deterministic metrics"))
        // Per-call: input 100, cache read 40, cache write 0, output 12, cost unknown.
        #expect(out.contains("| 1 | coach | gpt-5.5 | 200 | 500 | 100 | 40 | 0 | 12 | — |"))
        // Session totals sum both calls.
        #expect(out.contains("session totals: 2 calls · input 300 · cache-read 190 · cache-write 0 · output 32 · cost —"))
    }

    /// A transport-error call (no response) still gets a row — with its HTTP/ms and zeroed usage —
    /// so the auditor sees it happened without a usage blob to eyeball.
    @Test func rendersTransportErrorCallWithZeroUsage() throws {
        let failed = try line(status: nil, request: ["model": "gpt-5.5"], error: "timed out")
        let out = SessionMetrics.render(jsonl: failed)
        #expect(out.contains("| 1 | coach | gpt-5.5 | — | 500 | 0 | 0 | 0 | 0 | — |"))
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
}
