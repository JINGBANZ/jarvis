import Foundation
import Testing
import JarvisCore
@testable import JarvisEvaluation

@Suite struct SessionEvidenceIndexTests {
    @Test func inventoriesArtifactsDistributionsAndCorrelationCoverage() throws {
        func json(_ object: [String: Any]) throws -> String {
            try #require(String(
                data: JSONSerialization.data(withJSONObject: object),
                encoding: .utf8))
        }

        let traffic = try [
            json([
                "t": "10:00:00",
                "tag": "coach",
                "record_kind": BrainTrafficAuditEvent.Kind.providerCall.rawValue,
                "status": 200,
                "request": ["model": "model-a"],
                "coach_attempt": [
                    "id": 7,
                    "trigger": "turn_end",
                    "source_trigger": "turn_end",
                    "phase": "initial",
                ],
            ]),
            json([
                "t": "10:00:01",
                "tag": "summarizer",
                "record_kind": BrainTrafficAuditEvent.Kind.providerCall.rawValue,
                "status": 503,
                "request": ["model": "model-b"],
            ]),
            "{truncated",
        ].joined(separator: "\n")
        let attempts = try [
            json([
                "event": "started",
                "attempt": 7,
                "t": "10:00:00",
                "wake": "trigger",
                "trigger": "turn_end",
                "source_trigger": "turn_end",
                "provider": "openai",
                "model": "model-a",
                "transcript": [[
                    "index": 2,
                    "speaker": "them",
                    "at": 4.5,
                    "classification": "substantive",
                    "brain_facing": true,
                ]],
            ]),
            json([
                "event": "finished",
                "attempt": 7,
                "t": "10:00:02",
                "terminal": "speak",
                "outcome": "spoke",
            ]),
        ].joined(separator: "\n")
        let activity = try [
            json(["t": "10:00:00", "k": "heard", "o": 1.0, "q": 0, "r": 1.1]),
            json(["t": "10:00:02", "k": "tip", "o": 2.0, "q": 1, "r": 2.1]),
        ].joined(separator: "\n")

        let output = SessionEvidenceIndex.render(
            trafficJSONL: traffic,
            attemptsJSONL: attempts,
            activityJSONL: activity,
            healthJSON: #"{"version":1,"state":"complete"}"#,
            auditEvidence: .init(state: .complete, limitations: []))

        #expect(output.hasPrefix("=== session evidence index"))
        #expect(output.contains("descriptive, not diagnostic"))
        #expect(output.contains("| `brain-traffic.jsonl` | present | 2 | 1 |"))
        #expect(output.contains("| `coaching-attempts.jsonl` | present | 2 | 0 |"))
        #expect(output.contains("| `jarvis-activity.jsonl` | present | 2 | 0 |"))
        #expect(output.contains("| `audit-health.json` | present | 1 | 0 |"))
        #expect(output.contains("| brain-traffic.jsonl | `status` | 200: 1, 503: 1 | 2/2 |"))
        #expect(output.contains("| coaching-attempts.jsonl | `event` | finished: 1, started: 1 | 2/2 |"))
        #expect(output.contains("| attempt transcript entries | `brain_facing` | true: 1 | 1/1 |"))
        #expect(output.contains("| jarvis-activity.jsonl | `k` | heard: 1, tip: 1 | 2/2 |"))
        #expect(output.contains("| coach traffic records | `coach_attempt.id` | 1/1 |"))
        #expect(output.contains("| attempt transcript entries | `at` | 1/1 |"))
        #expect(output.contains("one-based nonblank-line anchors"))
    }

    @Test func missingArtifactsAndFieldsStayUnavailableWithoutDeclaringAnIncident() {
        let output = SessionEvidenceIndex.render(
            trafficJSONL: #"{"tag":"coach"}"#,
            attemptsJSONL: nil,
            activityJSONL: nil,
            healthJSON: nil,
            auditEvidence: .legacy)

        #expect(output.contains("| `coaching-attempts.jsonl` | missing | — | — |"))
        #expect(output.contains("| `jarvis-activity.jsonl` | missing | — | — |"))
        #expect(output.contains("| `audit-health.json` | missing | — | — |"))
        #expect(output.contains("| coach traffic records | `coach_attempt.id` | 0/1 |"))
        #expect(output.contains("missing field is not, by itself, a finding"))
        #expect(!output.contains("filler-only"))
        #expect(!output.contains("avoidable-call"))
        #expect(!output.contains("composite-filler misses"))
    }
}
