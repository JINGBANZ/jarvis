import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachingAttemptLogTests {
    @Test func recordsOwnerOnlyAttemptStartAndTerminalEvents() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = CoachingAttemptLog(); log.enable(directory: dir)
        let target = BrainTarget(provider: .codexCLI, modelID: "gpt-5.6-codex")
        let transcript = [
            TranscriptLine(speaker: .them, text: "Uh. Hmm.", at: 1),
            TranscriptLine(speaker: .them, text: "Explain the tradeoff", at: 2),
        ]
        log.recordStarted(
            attemptID: 3,
            wake: .trigger,
            reason: .silence(secondsQuiet: 45),
            target: target,
            transcriptStartIndex: 8,
            transcriptLines: transcript,
            classifications: transcript.map { TurnSubstance.classification(of: $0.text) })
        log.recordFinished(attemptID: 3, terminal: .staySilent, outcome: .silentByModel)

        let url = dir.appendingPathComponent(CoachingAttemptLog.filename)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)
        let events = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map {
                try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        #expect(events.count == 2)
        #expect(events[0]["event"] as? String == "started")
        #expect(events[0]["trigger"] as? String == "silence")
        #expect(events[0]["seconds_quiet"] as? Double == 45)
        #expect(events[0]["provider"] as? String == BrainProvider.codexCLI.rawValue)
        let lines = try #require(events[0]["transcript"] as? [[String: Any]])
        #expect(lines.map { $0["index"] as? Int } == [8, 9])
        #expect(lines[0]["classification"] as? String == "composite_filler")
        #expect(lines[0]["brain_facing"] as? Bool == false)
        #expect(lines[1]["brain_facing"] as? Bool == true)
        #expect(events[1]["terminal"] as? String == "stay_silent")
        #expect(events[1]["outcome"] as? String == "silent_by_model")
    }
}
