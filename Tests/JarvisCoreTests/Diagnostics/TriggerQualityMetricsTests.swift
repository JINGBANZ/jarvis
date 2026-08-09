import Foundation
import Testing
@testable import JarvisCore

@Suite struct TriggerQualityMetricsTests {
    @Test func fixtureSeparatesSkipsSilenceCompositeMissesAndScreenshotContinuations() throws {
        func json(_ object: [String: Any]) throws -> String {
            try #require(String(
                data: JSONSerialization.data(withJSONObject: object),
                encoding: .utf8))
        }
        func started(
            _ attempt: Int,
            trigger: String,
            index: Int?,
            classification: String? = nil,
            brainFacing: Bool = false
        ) throws -> String {
            let transcript: [[String: Any]]
            if let index, let classification {
                transcript = [[
                    "index": index,
                    "speaker": "them",
                    "text": "fixture line \(index)",
                    "classification": classification,
                    "brain_facing": brainFacing,
                ]]
            } else {
                transcript = []
            }
            return try json([
                "event": "started", "attempt": attempt,
                "trigger": trigger, "source_trigger": "turn_end",
                "transcript": transcript,
            ])
        }
        func finished(_ attempt: Int, terminal: String) throws -> String {
            try json(["event": "finished", "attempt": attempt, "terminal": terminal])
        }
        func traffic(
            _ attempt: Int,
            trigger: String,
            phase: String,
            recordKind: String = BrainTrafficLog.RecordKind.providerCall.rawValue
        ) throws -> String {
            try json([
                "tag": "coach",
                "record_kind": recordKind,
                "request": ["provider": "codex-cli", "model": "gpt-5.6-codex", "input": []],
                "response": ["reply": "{}", "runtime": ["status": "completed"]],
                "coach_attempt": [
                    "id": attempt, "trigger": trigger,
                    "source_trigger": "turn_end", "phase": phase, "sequence": 1,
                ],
            ])
        }

        let attempts = try [
            started(1, trigger: "turn_end", index: 0, classification: "known_filler"),
            finished(1, terminal: "skipped_filler"),
            started(2, trigger: "turn_end", index: 1, classification: "substantive", brainFacing: true),
            finished(2, terminal: "stay_silent"),
            // Simulates an older runtime's punctuation-separated filler miss reaching the brain.
            started(3, trigger: "turn_end", index: 2, classification: "composite_filler", brainFacing: true),
            finished(3, terminal: "speak"),
            started(4, trigger: "pending_work", index: nil),
            finished(4, terminal: "failure"),
            started(5, trigger: "turn_end", index: nil),
            finished(5, terminal: "failure"),
        ].joined(separator: "\n")
        let trafficJSONL = try [
            traffic(2, trigger: "turn_end", phase: "initial"),
            traffic(3, trigger: "turn_end", phase: "initial"),
            traffic(3, trigger: "turn_end", phase: "capture_screen_continuation"),
            traffic(4, trigger: "pending_work", phase: "initial"),
            traffic(
                5,
                trigger: "turn_end",
                phase: "initial",
                recordKind: BrainTrafficLog.RecordKind.preRequestFailure.rawValue),
        ].joined(separator: "\n")
        let activity = [
            #"{"k":"heard"}"#,
            #"{"k":"heard"}"#,
            #"{"k":"heard"}"#,
            #"{"k":"stayedSilent"}"#,
        ].joined(separator: "\n")

        let output = TriggerQualityMetrics.render(
            trafficJSONL: trafficJSONL,
            attemptsJSONL: attempts,
            activityJSONL: activity)

        #expect(output.contains("| finalized heard lines | 3 |"))
        #expect(output.contains("| known filler lines | 2 |"))
        #expect(output.contains("| filler-only turn ends skipped before a provider call | 1 |"))
        #expect(output.contains("| composite-filler misses that reached the brain | 1 |"))
        #expect(output.contains("| model `stay_silent` decisions | 1 |"))
        #expect(output.contains("| turn end | 3 |"))
        #expect(output.contains("| pending-work wake | 1 |"))
        #expect(output.contains("| initial coaching request | 3 |"))
        #expect(output.contains("| `capture_screen` continuation | 1 |"))
        #expect(output.contains("| CLI setup/pre-request failures before a provider call | 1 |"))
        #expect(output.contains("never an avoidable-call count"))
        #expect(output.contains("| cost | 0 | 4 |"))
    }

    @Test func missingProvenanceRendersUnavailableInsteadOfInventingZeros() {
        let traffic = #"{"tag":"coach","request":{"model":"gpt-5.5"}}"#
        let output = TriggerQualityMetrics.render(
            trafficJSONL: traffic,
            attemptsJSONL: nil,
            activityJSONL: nil)
        #expect(output.contains("| finalized heard lines | — |"))
        #expect(output.contains("| known filler lines | — |"))
        #expect(output.contains("| filler-only turn ends skipped before a provider call | — |"))
        #expect(output.contains("| unavailable | 1 |"))
    }

    @Test func malformedSourcesMakeAffectedCountsExplicitlyPartial() {
        let traffic = """
            {"tag":"coach","request":{"model":"gpt-5.5"},"coach_attempt":{"id":1,"trigger":"turn_end","phase":"initial"}}
            {truncated
            """
        let attempts = """
            {"event":"started","attempt":1,"transcript":[{"index":0,"classification":"substantive","brain_facing":true}]}
            {"event":"finished","attempt":1,"terminal":"stay_silent"}
            {truncated
            """
        let activity = """
            {"k":"heard"}
            {"k":"stayedSilent"}
            {truncated
            """

        let output = TriggerQualityMetrics.render(
            trafficJSONL: traffic,
            attemptsJSONL: attempts,
            activityJSONL: activity)

        #expect(output.contains("Evidence warning:"))
        #expect(output.contains("| finalized heard lines | 1 known (1 unavailable Activity record(s)) |"))
        #expect(output.contains("1 unavailable attempt record(s)"))
        #expect(output.contains("1 unavailable traffic join(s)"))
        #expect(output.contains("| malformed traffic record (call type unavailable) | 1 |"))
        #expect(output.contains("telemetry totals are partial"))
    }
}
