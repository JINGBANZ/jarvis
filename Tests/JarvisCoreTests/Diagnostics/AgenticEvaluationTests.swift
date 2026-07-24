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
        let activityLine =
            #"{"t":"10:00:30","m":"plain permanent failure","k":"coachingStopped"}"#
        try Data((activityLine + "\n").utf8)
            .write(to: dir.appendingPathComponent(ActivityLog.filename))

        let prompt = try AgenticEvaluation.prepare(sessionDir: dir)

        // The compact transcript is written beside the traffic, owner-only, with the rendered content.
        let transcriptURL = dir.appendingPathComponent(AgenticEvaluation.transcriptFilename)
        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        #expect(transcript.contains("=== call #1 · coach"))
        #expect(transcript.contains("=== human-facing runtime outcome ==="))
        #expect(transcript.contains("plain permanent failure"))
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
        #expect(prompt.contains(ActivityLog.filename))
    }

    /// The prompt teaches each provider record and cache model, preserves unavailable metrics,
    /// requires cardinal counts from the un-elided record, and asks for a self-check.
    @Test func promptTeachesEnvelopesCacheModelsCountingAndSelfCheck() {
        let prompt = AgenticEvaluation.prompt(sessionDirPath: "/tmp/session")
        #expect(prompt.contains("deterministic metrics"))
        #expect(prompt.contains("input_tokens_details.cached_tokens"))
        #expect(prompt.contains("cache_write_tokens"))
        #expect(prompt.contains("total_cost_usd"))
        #expect(prompt.contains("modelUsage"))
        #expect(prompt.contains("Codex CLI"))
        #expect(prompt.contains("unavailable, not zero"))
        #expect(prompt.contains("known (N unavailable)"))
        #expect(prompt.contains("BLOCK-level"))
        #expect(prompt.contains("--system-prompt"))
        // Cardinal counts must come from the un-elided jsonl, not the elided transcript.
        #expect(prompt.contains(BrainTrafficLog.filename))
        #expect(prompt.contains("MUST be counted here"))
        #expect(prompt.contains("re-check every number"))
        #expect(prompt.contains("session-level UX failure"))
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

    /// A transcript that can't be written must abort the audit — the prompt promises the agent the
    /// transcript exists, so proceeding would spend an agentic run on a missing/stale file.
    @Test func prepareThrowsWhenTranscriptCannotBeWritten() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = BrainTrafficLog(); traffic.enable(directory: dir)
        traffic.record(tag: "coach",
                       request: Data(#"{"model":"gpt-5.5","input":[]}"#.utf8),
                       response: Data(#"{"status":"completed","output":[]}"#.utf8),
                       status: 200, latencyMs: 300)
        // A directory squatting on the transcript path makes createFile fail.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(AgenticEvaluation.transcriptFilename),
            withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try AgenticEvaluation.prepare(sessionDir: dir)
        }
    }
}
