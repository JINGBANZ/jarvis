import Testing
import Foundation
@testable import JarvisCore

/// A brain that returns a canned report and remembers what it was asked.
/// `@unchecked Sendable`: `received` is written by `respond` and only read by the test after the
/// `await` returns — the sequential test flow means no concurrent access can occur.
private final class CannedBrain: BrainClient, @unchecked Sendable {
    let text: String?
    var received: [ChatMessage] = []
    init(text: String?) { self.text = text }
    func respond(messages: [ChatMessage], tools: [ToolDef],
                 toolChoice: ToolChoice) async throws -> BrainResponse {
        received = messages
        return BrainResponse(toolCalls: [], outputText: text)
    }
}

@Suite struct SessionEvaluatorTests {
    /// One traffic line in the on-disk shape `BrainTrafficLog` writes.
    private func line(tag: String = "coach", request: [String: Any],
                      response: [String: Any]? = nil, error: String? = nil) throws -> String {
        var entry: [String: Any] = ["t": "10:00:00", "tag": tag, "ms": 500, "request": request]
        if response != nil { entry["status"] = 200 }
        entry["response"] = response
        entry["error"] = error
        return try #require(String(data: JSONSerialization.data(withJSONObject: entry), encoding: .utf8))
    }

    private func userItem(_ text: String) -> [String: Any] {
        ["role": "user", "content": [["type": "input_text", "text": text]]]
    }

    @Test func transcriptElidesUnchangedPrefixInstructionsAndTools() throws {
        let tools: [[String: Any]] = [["type": "function", "name": "speak"]]
        let first = try line(request: ["model": "gpt-5.5", "instructions": "SYS",
                                       "tools": tools, "input": [userItem("turn one")]],
                             response: ["status": "completed", "output": [],
                                        "usage": ["input_tokens": 100]])
        let second = try line(request: ["model": "gpt-5.5", "instructions": "SYS",
                                        "tools": tools,
                                        "input": [userItem("turn one"), userItem("turn two")]],
                              response: ["status": "completed", "output": [],
                                         "usage": ["input_tokens": 120]])
        let out = SessionEvaluator.renderTranscript(jsonl: "\(first)\n\(second)")

        #expect(out.contains("=== call #1 · coach · 10:00:00 · HTTP 200 · 500 ms"))
        #expect(out.contains("instructions (3 chars):\nSYS"))
        #expect(out.contains("instructions: (unchanged — 3 chars)"))
        #expect(out.contains("[items 1–1 unchanged from the previous coach call"))
        #expect(out.contains("tools: (unchanged — 1 defs)"))
        // The shared first item renders exactly once; the second call shows only its delta.
        #expect(out.ranges(of: "user: turn one").count == 1)
        #expect(out.contains("user: turn two"))
        #expect(out.contains(#""input_tokens":100"#))
    }

    /// Different tags never share an elision baseline: a summarizer call between two coach calls
    /// must not break the coach's unchanged-prefix detection (or claim the summarizer's input as
    /// its own baseline).
    @Test func transcriptTracksElisionPerTag() throws {
        let coach1 = try line(request: ["model": "gpt-5.5", "input": [userItem("coach turn")]])
        let sum = try line(tag: "summarizer",
                           request: ["model": "gpt-5.4-mini", "input": [userItem("condense this")]])
        let coach2 = try line(request: ["model": "gpt-5.5",
                                        "input": [userItem("coach turn"), userItem("more")]])
        let out = SessionEvaluator.renderTranscript(jsonl: [coach1, sum, coach2].joined(separator: "\n"))
        #expect(out.contains("[items 1–1 unchanged from the previous coach call"))
        #expect(out.contains("user: condense this"))
    }

    @Test func transcriptRendersToolCallsResultsAndTransportErrors() throws {
        let callItems: [[String: Any]] = [
            userItem("look please"),
            ["type": "function_call", "call_id": "c1", "name": "capture_screen", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "c1", "output": "screenshot captured"],
        ]
        let ok = try line(request: ["model": "gpt-5.5", "input": callItems],
                          response: ["status": "completed",
                                     "output": [["type": "reasoning"],
                                                ["type": "function_call", "call_id": "c2",
                                                 "name": "speak", "arguments": #"{"lines":["tip"]}"#]],
                                     "usage": ["output_tokens": 42]])
        let failed = try line(request: ["model": "gpt-5.5", "input": [userItem("hello")]],
                              error: "timed out")
        let out = SessionEvaluator.renderTranscript(jsonl: "\(ok)\n\(failed)")

        #expect(out.contains("assistant → function_call capture_screen({})"))
        #expect(out.contains("tool result: screenshot captured"))
        #expect(out.contains(#"→ function_call speak({"lines":["tip"]})"#))
        #expect(!out.contains("reasoning"))                    // empty reasoning stubs carry no signal
        #expect(out.contains("TRANSPORT ERROR: timed out"))
        #expect(out.contains("=== call #2"))
    }

    /// Replayed reasoning items on the INPUT side (the tool loop's verbatim passthrough) render as a
    /// one-line stub — the bytes are opaque (ids, possibly a large `encrypted_content` blob) and
    /// would only bloat the audit transcript.
    @Test func transcriptStubsReplayedReasoningInputItems() throws {
        let blob = String(repeating: "A", count: 256)
        let items: [[String: Any]] = [
            userItem("look please"),
            ["type": "reasoning", "id": "rs_1", "summary": [], "encrypted_content": blob],
            ["type": "function_call", "call_id": "c1", "name": "capture_screen", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "c1", "output": "screenshot captured"],
        ]
        let out = SessionEvaluator.renderTranscript(jsonl: try line(request: ["model": "gpt-5.5",
                                                                              "input": items]))
        #expect(out.contains("assistant reasoning (replayed verbatim — "))
        #expect(out.contains("chars)"))
        #expect(!out.contains(blob))                              // the opaque payload never renders
        #expect(out.contains("assistant → function_call capture_screen({})"))
    }

    /// The transcript now leads with the deterministic metrics table, before the first call block,
    /// so the auditor reads computed numbers before any usage blob.
    @Test func transcriptLeadsWithDeterministicMetrics() throws {
        let call = try line(request: ["model": "gpt-5.5", "input": [userItem("hi")]],
                            response: ["status": "completed", "output": [],
                                       "usage": ["input_tokens": 100,
                                                 "input_tokens_details": ["cached_tokens": 40],
                                                 "output_tokens": 12]])
        let out = SessionEvaluator.renderTranscript(jsonl: call)
        #expect(out.hasPrefix("=== deterministic metrics"))
        #expect(out.contains("| call | tag | model |"))
        let metrics = try #require(out.range(of: "deterministic metrics"))
        let firstCall = try #require(out.range(of: "=== call #1"))
        #expect(metrics.lowerBound < firstCall.lowerBound)
    }

    /// The audit prompt teaches each provider record, preserves unavailable metrics, points at the
    /// computed values, and requires a self-verification pass.
    @Test func evalInstructionsTeachEnvelopesMetricsAndSelfCheck() {
        let p = SessionEvaluator.evalInstructions
        #expect(p.contains("deterministic metrics"))
        #expect(p.contains("input_tokens_details.cached_tokens"))
        #expect(p.contains("cache_write_tokens"))
        #expect(p.contains("total_cost_usd"))
        #expect(p.contains("modelUsage"))
        #expect(p.contains("Codex CLI"))
        #expect(p.contains("unavailable, not zero"))
        #expect(p.contains("known (N unavailable)"))
        #expect(p.contains("re-check every number"))
        #expect(p.contains("human-facing runtime outcome"))
        #expect(p.contains("session-level UX failure"))
    }

    @Test func activityOutcomeRendersOnlyFixedStopAndDegradeNotices() {
        let jsonl = [
            #"{"t":"10:00:00","m":"🗣 heard (me): \"hello\""}"#,
            #"{"t":"10:00:30","m":"⚠️ Codex CLI couldn't respond this turn — listening continues"}"#,
            #"{"t":"10:00:40","m":"💬 try a hash map"}"#,
            #"{"t":"10:01:00","m":"⏹ coaching stopped — Codex CLI couldn't respond; check Settings → Brain"}"#,
        ].joined(separator: "\n")

        let outcome = SessionEvaluator.renderActivityOutcome(jsonl: jsonl)

        #expect(outcome.hasPrefix("=== human-facing runtime outcome ==="))
        #expect(outcome.contains("[10:00:30] ⚠️ Codex CLI couldn't respond this turn"))
        #expect(outcome.contains("[10:01:00] ⏹ coaching stopped"))
        #expect(!outcome.contains("heard"))
        #expect(!outcome.contains("hash map"))
    }

    @Test func activityOutcomeUsesStableKindsInsteadOfHumanCopy() throws {
        let lines = ActivityLog.EventKind.allCases.map { kind in
            let record: [String: Any] = [
                "t": "10:00:00",
                "m": "plain copy for \(kind.rawValue)",
                "k": kind.rawValue,
            ]
            return String(data: try! JSONSerialization.data(withJSONObject: record),
                          encoding: .utf8)!
        }

        let outcome = SessionEvaluator.renderActivityOutcome(
            jsonl: lines.joined(separator: "\n"))

        for kind in ActivityLog.EventKind.allCases {
            #expect(outcome.contains("plain copy for \(kind.rawValue)")
                == kind.isEvaluationOutcome)
        }
    }

    @Test func evaluateSendsTranscriptAndPersistsOwnerOnlyReport() async throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = BrainTrafficLog(); traffic.enable(directory: dir)
        traffic.record(tag: "coach",
                       request: Data(#"{"model":"gpt-5.5","input":[]}"#.utf8),
                       response: Data(#"{"status":"completed","output":[]}"#.utf8),
                       status: 200, latencyMs: 300)
        let activityLine =
            #"{"t":"10:00:30","m":"⏹ coaching stopped — Codex CLI couldn't respond; check Settings → Brain"}"#
        try Data((activityLine + "\n").utf8)
            .write(to: dir.appendingPathComponent(ActivityLog.filename))
        let brain = CannedBrain(text: "## Context engineering\nall good")
        let report = try await SessionEvaluator(brain: brain).evaluate(sessionDir: dir)

        // The model's text is preserved verbatim, preceded by the provenance stamp.
        #expect(report.hasSuffix("## Context engineering\nall good"))
        #expect(report.contains(SessionEvaluator.provenanceStamp))
        #expect(brain.received.first?.role == .system)
        #expect(brain.received.last?.text?.contains("=== call #1 · coach") == true)
        #expect(brain.received.last?.text?.contains("=== human-facing runtime outcome ===") == true)
        #expect(brain.received.last?.text?.contains("⏹ coaching stopped") == true)
        let url = dir.appendingPathComponent(SessionEvaluator.reportFilename)
        #expect(try String(contentsOf: url, encoding: .utf8) == report)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    @Test func evaluateFlushesPendingActivityBeforeReadingOutcomes() async throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = BrainTrafficLog(); traffic.enable(directory: dir)
        traffic.record(tag: "coach",
                       request: Data(#"{"model":"gpt-5.5","input":[]}"#.utf8),
                       response: Data(#"{"status":"completed","output":[]}"#.utf8),
                       status: 200, latencyMs: 300)
        let activity = ActivityLog()
        activity.enable(directory: dir)
        activity.record(.coachingStopped(provider: .codexCLI))
        let brain = CannedBrain(text: "## Audit\ncaught it")

        _ = try await SessionEvaluator(brain: brain, activityLog: activity)
            .evaluate(sessionDir: dir)

        #expect(brain.received.last?.text?.contains("coaching stopped") == true)
    }

    /// `savedReport` is the "Show report" gate: nil until an evaluation persisted a report, then the
    /// exact saved text — and an empty file (a failed/interrupted write) must not count as a report.
    @Test func savedReportReturnsPersistedReportOnly() async throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SessionEvaluator.savedReport(in: dir) == nil)

        let traffic = BrainTrafficLog(); traffic.enable(directory: dir)
        traffic.record(tag: "coach",
                       request: Data(#"{"model":"gpt-5.5","input":[]}"#.utf8),
                       response: Data(#"{"status":"completed","output":[]}"#.utf8),
                       status: 200, latencyMs: 300)
        let report = try await SessionEvaluator(brain: CannedBrain(text: "## Audit\nfine")).evaluate(sessionDir: dir)
        #expect(SessionEvaluator.savedReport(in: dir) == report)

        try Data().write(to: dir.appendingPathComponent(SessionEvaluator.reportFilename))
        #expect(SessionEvaluator.savedReport(in: dir) == nil)
    }

    @Test func evaluateThrowsWhenSessionHasNoTraffic() async throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!SessionEvaluator.hasTraffic(in: dir))
        await #expect(throws: SessionEvaluator.EvaluationError.noTraffic) {
            try await SessionEvaluator(brain: CannedBrain(text: "unused")).evaluate(sessionDir: dir)
        }
    }

    @Test func evaluateThrowsWhenModelReturnsNoText() async throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = BrainTrafficLog(); traffic.enable(directory: dir)
        traffic.record(tag: "coach", request: Data(#"{"model":"gpt-5.5"}"#.utf8),
                       response: Data("{}".utf8), status: 200, latencyMs: 1)
        #expect(SessionEvaluator.hasTraffic(in: dir))
        await #expect(throws: SessionEvaluator.EvaluationError.emptyReport) {
            try await SessionEvaluator(brain: CannedBrain(text: nil)).evaluate(sessionDir: dir)
        }
    }
}
