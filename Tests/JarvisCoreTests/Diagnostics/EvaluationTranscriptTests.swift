import Testing
import Foundation
@testable import JarvisCore

@Suite struct EvaluationTranscriptTests {
    /// One traffic line in the on-disk shape `BrainTrafficLog` writes.
    private func line(tag: String = "coach", request: [String: Any],
                      response: [String: Any]? = nil, error: String? = nil,
                      coachAttempt: [String: Any]? = nil,
                      recordKind: String? = nil) throws -> String {
        var entry: [String: Any] = ["t": "10:00:00", "tag": tag, "ms": 500, "request": request]
        if response != nil { entry["status"] = 200 }
        entry["response"] = response
        entry["error"] = error
        entry["coach_attempt"] = coachAttempt
        entry["record_kind"] = recordKind
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
        let out = EvaluationTranscript.render(jsonl: "\(first)\n\(second)")

        #expect(out.contains(
            "=== call #1 · coach · 10:00:00 · OpenAI API · HTTP 200 · 500 ms"))
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
        let out = EvaluationTranscript.render(jsonl: [coach1, sum, coach2].joined(separator: "\n"))
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
        let out = EvaluationTranscript.render(jsonl: "\(ok)\n\(failed)")

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
        let out = EvaluationTranscript.render(jsonl: try line(request: ["model": "gpt-5.5",
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
        let out = EvaluationTranscript.render(jsonl: call)
        #expect(out.hasPrefix("=== deterministic metrics"))
        #expect(out.contains("| call | tag | provider | model |"))
        let metrics = try #require(out.range(of: "deterministic metrics"))
        let firstCall = try #require(out.range(of: "=== call #1"))
        #expect(metrics.lowerBound < firstCall.lowerBound)
    }

    @Test func mixedProvidersNeverShareAnElisionBaseline() throws {
        let openAI = try line(
            request: ["model": "gpt-5.5", "instructions": "SYS",
                      "input": [userItem("same conversation")]])
        let claude = try line(
            request: ["provider": "claude-code", "model": "sonnet",
                      "instructions": "SYS", "input": [userItem("same conversation")]])
        let out = EvaluationTranscript.render(jsonl: "\(openAI)\n\(claude)")

        #expect(out.contains("· OpenAI API"))
        #expect(out.contains("· Claude Code"))
        #expect(out.ranges(of: "instructions (3 chars):\nSYS").count == 2)
        #expect(out.ranges(of: "user: same conversation").count == 2)
        #expect(!out.contains("previous coach call"))
    }

    @Test func differentModelsFromTheSameProviderNeverShareAnElisionBaseline() throws {
        let sonnet = try line(
            request: ["provider": "claude-code", "model": "sonnet",
                      "instructions": "SYS", "input": [userItem("same conversation")]])
        let opus = try line(
            request: ["provider": "claude-code", "model": "opus",
                      "instructions": "SYS", "input": [userItem("same conversation")]])
        let out = EvaluationTranscript.render(jsonl: "\(sonnet)\n\(opus)")

        #expect(out.ranges(of: "instructions (3 chars):\nSYS").count == 2)
        #expect(out.ranges(of: "user: same conversation").count == 2)
        #expect(!out.contains("previous coach call"))
    }

    @Test func growingCLITextItemElidesItsSubstantialCommonPrefix() throws {
        let stable = String(repeating: "stable history line\n", count: 500)
        let firstText = "full conversation\n\(stable)old turn trailer"
        let secondText = "full conversation\n\(stable)new transcript delta"
        let first = try line(request: [
            "provider": "codex-cli", "model": "gpt-5.6-codex",
            "input": [["type": "text", "text": firstText]],
        ])
        let second = try line(request: [
            "provider": "codex-cli", "model": "gpt-5.6-codex",
            "input": [["type": "text", "text": secondText]],
        ])

        let output = EvaluationTranscript.render(jsonl: "\(first)\n\(second)")

        #expect(output.contains("within this CLI text item"))
        #expect(output.contains("full input remains in \(BrainTrafficLog.filename)"))
        #expect(output.ranges(of: "stable history line").count == 500)
        #expect(output.contains("new transcript delta"))
        #expect(output.utf8.count * 4 < (firstText.utf8.count + secondText.utf8.count) * 3)
        #expect(output.contains("=== call #2"))
    }

    @Test func CLIReplyAppearsOnceWhenRuntimeEnvelopeRepeatsIt() throws {
        let reply = #"{"tool":"stay_silent","arguments":{}}"#
        let call = try line(
            request: ["provider": "codex-cli", "model": "gpt-5.6-codex", "input": []],
            response: [
                "reply": reply,
                "runtime": [
                    "status": "completed",
                    "items": [["type": "agentMessage", "text": reply]],
                    "itemsView": [["type": "agentMessage", "text": reply]],
                ],
            ])

        let output = EvaluationTranscript.render(jsonl: call)

        #expect(output.ranges(of: reply).count == 1)
        #expect(output.ranges(of: "[duplicate of response.reply omitted]").count == 2)
    }

    @Test func callLabelsTranscriptInputJarvisOutputAndTriggerUnambiguously() throws {
        let reply = #"{"tool":"speak","arguments":{"lines":["I opened LeetCode."]}}"#
        let call = try line(
            request: [
                "provider": "codex-cli", "model": "gpt-5.6-codex",
                "input": [["type": "text", "text": "[00:01] them: Open LeetCode and share your screen"]],
            ],
            response: ["reply": reply],
            coachAttempt: [
                "id": 12, "trigger": "turn_end", "source_trigger": "turn_end",
                "phase": "initial", "sequence": 1,
            ])

        let output = EvaluationTranscript.render(jsonl: call)

        #expect(output.contains("attempt #12 · trigger=turn_end · phase=initial"))
        #expect(output.contains("brain request input (1 items):"))
        #expect(output.contains("them: Open LeetCode and share your screen"))
        #expect(output.contains("Jarvis brain output:"))
        #expect(output.contains("I opened LeetCode."))
    }

    @Test func malformedTrafficIsVisibleAndDoesNotRenumberLaterCalls() throws {
        let first = try line(request: ["model": "gpt-5.5", "input": [userItem("one")]])
        let third = try line(request: ["model": "gpt-5.5", "input": [userItem("three")]])

        let output = EvaluationTranscript.render(jsonl: "\(first)\n{truncated\n\(third)")

        #expect(output.contains("=== record #2 · malformed traffic entry"))
        #expect(output.contains("=== call #3"))
        #expect(output.contains("all session totals below are partial"))
    }

    @Test func preRequestFailureIsNotLabeledAsAProviderCall() throws {
        let setupFailure = try line(
            request: ["provider": "codex-cli", "runtime": "app-server"],
            error: "app-server unavailable",
            recordKind: BrainTrafficLog.RecordKind.preRequestFailure.rawValue)

        let output = EvaluationTranscript.render(jsonl: setupFailure)

        #expect(output.contains("=== record #1 · coach"))
        #expect(output.contains("pre-request failure (no provider call)"))
        #expect(!output.contains("=== call #1 · coach"))
    }

}
