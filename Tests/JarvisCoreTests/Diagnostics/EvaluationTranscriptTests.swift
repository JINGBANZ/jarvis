import Testing
import Foundation
@testable import JarvisCore

@Suite struct EvaluationTranscriptTests {
    /// One traffic line in the on-disk shape `FileSessionAudit` writes.
    private func line(tag: String = "coach", request: [String: Any],
                      response: [String: Any]? = nil, error: String? = nil,
                      coachAttempt: [String: Any]? = nil,
                      recordKind: String? = nil,
                      auditVersion: Int? = nil) throws -> String {
        var entry: [String: Any] = ["t": "10:00:00", "tag": tag, "ms": 500, "request": request]
        if response != nil { entry["status"] = 200 }
        entry["response"] = response
        entry["error"] = error
        entry["coach_attempt"] = coachAttempt
        entry["record_kind"] = recordKind
        entry["audit_version"] = auditVersion
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

    /// The transcript leads with neutral evidence tools before the first compact traffic block.
    @Test func transcriptLeadsWithEvidenceIndexAndProviderTelemetry() throws {
        let call = try line(request: ["model": "gpt-5.5", "input": [userItem("hi")]],
                            response: ["status": "completed", "output": [],
                                       "usage": ["input_tokens": 100,
                                                 "input_tokens_details": ["cached_tokens": 40],
                                                 "output_tokens": 12]])
        let out = EvaluationTranscript.render(jsonl: call)
        #expect(out.hasPrefix("=== session evidence index"))
        #expect(out.contains("=== provider-call telemetry"))
        #expect(out.contains("| call | tag | provider | model |"))
        let index = try #require(out.range(of: "session evidence index"))
        let metrics = try #require(out.range(of: "provider-call telemetry"))
        let firstCall = try #require(out.range(of: "=== call #1"))
        #expect(index.lowerBound < metrics.lowerBound)
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
        #expect(output.contains("full input remains in \(FileSessionAudit.brainTrafficFilename)"))
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
            recordKind: BrainTrafficAuditEvent.Kind.preRequestFailure.rawValue)

        let output = EvaluationTranscript.render(jsonl: setupFailure)

        #expect(output.contains("=== record #1 · coach"))
        #expect(output.contains("pre-request failure (no provider call)"))
        #expect(!output.contains("=== call #1 · coach"))
    }

    @Test func incompleteAuditMarkerMakesEveryAuditCountAnExplicitLowerBound() throws {
        let traffic = try line(
            request: ["model": "gpt-5.5", "input": [userItem("hi")]],
            response: ["usage": ["input_tokens": 10, "output_tokens": 2]],
            coachAttempt: [
                "id": 1, "trigger": "turn_end", "source_trigger": "turn_end",
                "phase": "initial", "sequence": 1,
            ],
            auditVersion: FileSessionAudit.formatVersion)
        let attempts =
            #"{"audit_version":1,"event":"started","attempt":1,"transcript":[]}"#
            + "\n"
            + #"{"audit_version":1,"event":"finished","attempt":1,"terminal":"speak"}"#
        let health = #"{"version":1,"state":"partial","queue_overflow":2,"oversize_record":0,"open_failure":0,"write_failure":0,"serialization_failure":0}"#

        let output = EvaluationTranscript.render(
            jsonl: traffic,
            attemptsJSONL: attempts,
            activityJSONL: #"{"k":"heard"}"#,
            healthJSON: health)

        #expect(output.contains("session audit evidence is partial"))
        #expect(output.contains("queue overflow: 2"))
        #expect(output.contains(
            "known recorded totals: 1 known calls (session total unavailable)"))
        #expect(output.contains("| coach traffic records | `coach_attempt.id` | 1/1 |"))
        #expect(output.contains("| `audit-health.json` | present | 1 | 0 |"))
        #expect(output.contains("health marker reports partial evidence; queue overflow: 2"))
        #expect(output.contains("session total unavailable"))
    }

    @Test func missingMarkerIsPartialOnlyForTheVersionedFormat() throws {
        let newTraffic = try line(
            request: ["model": "gpt-5.5", "input": []],
            auditVersion: FileSessionAudit.formatVersion)
        let oldTraffic = try line(request: ["model": "gpt-5.5", "input": []])

        let newOutput = EvaluationTranscript.render(jsonl: newTraffic)
        let oldOutput = EvaluationTranscript.render(jsonl: oldTraffic)

        #expect(newOutput.contains("completion marker missing"))
        #expect(newOutput.contains("known recorded totals"))
        #expect(oldOutput.contains("historical format without a completion marker"))
        #expect(oldOutput.contains("session totals: 1 calls"))
    }

    @Test func inProgressMarkerIsExplicitlyIncomplete() {
        let evidence = SessionAuditEvidence.assess(
            trafficJSONL: "",
            attemptsJSONL: "",
            healthJSON: #"{"version":1,"state":"in_progress","queue_overflow":0,"oversize_record":0,"open_failure":0,"write_failure":0,"serialization_failure":0}"#)

        #expect(evidence.state == .partial)
        #expect(evidence.limitations.contains("session close incomplete"))
    }

    @Test func incompleteHealthSchemaCannotBeMistakenForCompleteEvidence() {
        let evidence = SessionAuditEvidence.assess(
            trafficJSONL: "",
            attemptsJSONL: "",
            healthJSON: #"{"version":1,"state":"complete"}"#)

        #expect(evidence.state == .partial)
        #expect(evidence.limitations.contains {
            $0.contains("health marker field queue_overflow missing or invalid")
        })
    }

}
