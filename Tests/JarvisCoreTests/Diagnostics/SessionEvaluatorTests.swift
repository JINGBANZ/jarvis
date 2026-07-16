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

    @Test func evaluateSendsTranscriptAndPersistsOwnerOnlyReport() async throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = BrainTrafficLog(); traffic.enable(directory: dir)
        traffic.record(tag: "coach",
                       request: Data(#"{"model":"gpt-5.5","input":[]}"#.utf8),
                       response: Data(#"{"status":"completed","output":[]}"#.utf8),
                       status: 200, latencyMs: 300)
        let brain = CannedBrain(text: "## Context engineering\nall good")
        let report = try await SessionEvaluator(brain: brain).evaluate(sessionDir: dir)

        #expect(report == "## Context engineering\nall good")
        #expect(brain.received.first?.role == .system)
        #expect(brain.received.last?.text?.contains("=== call #1 · coach") == true)
        let url = dir.appendingPathComponent(SessionEvaluator.reportFilename)
        #expect(try String(contentsOf: url, encoding: .utf8) == report)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
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
