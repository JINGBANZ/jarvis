import Testing
import Foundation
@testable import JarvisCore

@Suite struct AgenticEvaluationTests {
    /// `prepare` renders the traffic to an owner-only transcript file beside it and returns a prompt
    /// that points the agent at the session dir + repo.
    @Test func prepareWritesOwnerOnlyTranscriptAndReturnsPrompt() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = BrainTrafficLog(); traffic.enable(directory: dir)
        traffic.record(tag: "coach",
                       request: Data(#"{"model":"gpt-5.5","input":[]}"#.utf8),
                       response: Data(#"{"status":"completed","output":[]}"#.utf8),
                       status: 200, latencyMs: 300)

        let prompt = try AgenticEvaluation.prepare(sessionDir: dir)

        // The compact transcript is written beside the traffic, owner-only, with the rendered content.
        let transcriptURL = dir.appendingPathComponent(AgenticEvaluation.transcriptFilename)
        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        #expect(transcript.contains("=== call #1 · coach"))
        let perms = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)

        // The prompt names the session dir, the report skeleton, the confirmed/hypothesis discipline,
        // and the code the auditor is told to verify against.
        #expect(prompt.contains(dir.path))
        #expect(prompt.contains(AgenticEvaluation.transcriptFilename))
        #expect(prompt.contains("## Context engineering"))
        #expect(prompt.contains("## Recommendations"))
        #expect(prompt.contains("[confirmed]"))
        #expect(prompt.contains("[hypothesis]"))
        #expect(prompt.contains("CoachHistory.swift"))
        #expect(prompt.contains(AgenticEvaluation.reportFilename))
    }

    /// Shares the report filename with the single-call path, so "Show report" and the viewer find a
    /// report whichever evaluator produced it.
    @Test func reportFilenameMatchesSingleCallPath() {
        #expect(AgenticEvaluation.reportFilename == SessionEvaluator.reportFilename)
    }

    @Test func prepareThrowsWhenSessionHasNoTraffic() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SessionEvaluator.EvaluationError.noTraffic) {
            try AgenticEvaluation.prepare(sessionDir: dir)
        }
        // No transcript file is left behind on the empty-traffic path.
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(AgenticEvaluation.transcriptFilename).path))
    }
}
