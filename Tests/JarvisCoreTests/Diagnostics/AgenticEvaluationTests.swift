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
        traffic.flush()
        let activityJSONL = [
            #"{"t":"10:00:00","m":"heard question","k":"heard"}"#,
            #"{"t":"10:00:20","m":"coaching tip","k":"tip"}"#,
            #"{"t":"10:00:30","m":"session ended by error","k":"sessionEnded"}"#,
        ].joined(separator: "\n") + "\n"
        let activityURL = dir.appendingPathComponent(ActivityLog.filename)
        try Data(activityJSONL.utf8).write(to: activityURL)
        let legacyRuntimeHome = dir.appendingPathComponent(
            ".codex-runtime-abandoned",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyRuntimeHome,
            withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: legacyRuntimeHome.appendingPathComponent("auth.json"),
            withDestinationURL: URL(fileURLWithPath: "/private/credential"))

        let prompt = try AgenticEvaluation.prepare(sessionDir: dir)

        #expect(!FileManager.default.fileExists(atPath: legacyRuntimeHome.path))
        // The compact transcript is written beside the traffic, owner-only, with the rendered content.
        let transcriptURL = dir.appendingPathComponent(AgenticEvaluation.transcriptFilename)
        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        #expect(transcript.contains("=== call #1 · coach"))
        #expect(!transcript.contains("heard question"))
        #expect(!transcript.contains("coaching tip"))
        #expect(!transcript.contains("session ended by error"))
        let perms = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
        // Preparation never rewrites or filters Activity; the agent receives the complete source file.
        #expect(try String(contentsOf: activityURL, encoding: .utf8) == activityJSONL)

        // The prompt names the session dir, report skeleton, provenance, and evidence discipline,
        // and the code the auditor is told to verify against.
        #expect(prompt.contains(dir.path))
        #expect(prompt.contains(AgenticEvaluation.transcriptFilename))
        #expect(prompt.contains("## Context engineering"))
        #expect(prompt.contains("## Recommendations"))
        #expect(prompt.contains("[session-proven]"))
        #expect(prompt.contains("[source-confirmed]"))
        #expect(prompt.contains("[hypothesis]"))
        #expect(prompt.contains("[preserve]"))
        #expect(prompt.contains("Sources/JarvisCore/Prompts/"))
        #expect(prompt.contains("all predefined model-facing prompt"))
        #expect(prompt.contains("split by domain"))
        #expect(prompt.contains("CoachHistory.swift"))
        #expect(prompt.contains(AgenticEvaluation.reportFilename))
        #expect(prompt.contains(ActivityLog.filename))
        #expect(prompt.contains(CoachingAttemptLog.filename))
        #expect(prompt.contains("COMPLETE sanitized human-facing coaching record"))
        #expect(prompt.contains("Read the file itself in full"))
        #expect(prompt.contains("deliberately NOT filtered, summarized"))
    }

    @Test func prepareReplacesTranscriptSoAFailedEvaluatorCanBeRetried() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = BrainTrafficLog(); traffic.enable(directory: dir)
        traffic.record(tag: "coach",
                       request: Data(#"{"model":"gpt-5.5","input":[]}"#.utf8),
                       response: Data(#"{"status":"completed","output":[]}"#.utf8),
                       status: 200, latencyMs: 300)
        traffic.flush()
        try Data().write(to: dir.appendingPathComponent(ActivityLog.filename))

        _ = try AgenticEvaluation.prepare(sessionDir: dir)
        let transcriptURL = dir.appendingPathComponent(AgenticEvaluation.transcriptFilename)
        try Data("stale partial transcript".utf8).write(to: transcriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: transcriptURL.path)

        _ = try AgenticEvaluation.prepare(sessionDir: dir)

        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        #expect(transcript.contains("=== call #1 · coach"))
        #expect(!transcript.contains("stale partial transcript"))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: transcriptURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)
    }

    /// The prompt teaches each provider record and conversation boundary, preserves unavailable
    /// metrics, requires cardinal counts from the un-elided record, and asks for a self-check.
    @Test func promptTeachesEnvelopesCacheModelsCountingAndSelfCheck() {
        let prompt = AgenticEvaluation.prompt(sessionDirPath: "/tmp/session")
        #expect(prompt.contains("deterministic metrics"))
        #expect(prompt.contains("input_tokens_details.cached_tokens"))
        #expect(prompt.contains("cache_write_tokens"))
        #expect(prompt.contains("total_cost_usd"))
        #expect(prompt.contains("modelUsage"))
        #expect(prompt.contains("Claude Code warm query"))
        #expect(prompt.contains("Codex app-server"))
        #expect(prompt.contains("response.runtime"))
        #expect(prompt.contains("unavailable, not zero"))
        #expect(prompt.contains("known (N unavailable)"))
        #expect(prompt.contains("malformed-record warning"))
        #expect(prompt.contains("NOT provider calls"))
        #expect(prompt.contains("actual `brain_facing` request inclusion"))
        #expect(prompt.contains("do not recompute one from the other"))
        #expect(prompt.contains("preinitialized query"))
        #expect(prompt.contains("incremental input"))
        #expect(prompt.contains("ClaudeCodeRuntime.swift"))
        #expect(prompt.contains("CodexAppServerRuntime.swift"))
        // Cardinal counts must come from the un-elided jsonl, not the elided transcript.
        #expect(prompt.contains(BrainTrafficLog.filename))
        #expect(prompt.contains("MUST be counted here"))
        #expect(prompt.contains("re-check every number"))
        #expect(prompt.contains("session-level UX failure"))
        #expect(prompt.contains("`session ended by error`"))
        #expect(!prompt.contains("coaching stopped"))
        #expect(!prompt.contains("session failed"))
        #expect(prompt.contains("stable event kinds in `k`"))
        #expect(prompt.contains("## Transcription and trigger quality"))
        #expect(prompt.contains("NEVER a proxy for an avoidable call"))
        #expect(prompt.contains("Raw audio is intentionally not retained"))
        #expect(prompt.contains("never claim a word was mistranscribed"))
        #expect(prompt.contains("Jarvis brain output generated"))
        #expect(prompt.contains("At most THREE"))
    }

    /// `savedReport` is the Activity viewer's discovery gate: an empty or absent file is not a report.
    @Test func savedReportReturnsOnlyPersistedAgenticReport() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AgenticEvaluation.savedReport(in: dir) == nil)
        let url = dir.appendingPathComponent(AgenticEvaluation.reportFilename)
        try Data("## Audit\nfine".utf8).write(to: url)
        #expect(AgenticEvaluation.savedReport(in: dir) == "## Audit\nfine")
        try Data().write(to: url)
        #expect(AgenticEvaluation.savedReport(in: dir) == nil)
    }

    @Test func hasTrafficRequiresANonemptyTrafficFile() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!AgenticEvaluation.hasTraffic(in: dir))
        let url = dir.appendingPathComponent(BrainTrafficLog.filename)
        try Data().write(to: url)
        #expect(!AgenticEvaluation.hasTraffic(in: dir))
        try Data("{}\n".utf8).write(to: url)
        #expect(AgenticEvaluation.hasTraffic(in: dir))
    }

    @Test func saveReportAtomicallyReplacesAnOlderOwnerOnlyReport() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(AgenticEvaluation.reportFilename)
        try Data("old report".utf8).write(to: url)

        let saved = try AgenticEvaluation.saveReport(
            "## New audit\nall good", agentName: "codex", in: dir)

        #expect(try String(contentsOf: url, encoding: .utf8) == saved)
        #expect(saved.contains("Produced by the agentic evaluator (`codex`"))
        #expect(saved.contains("## New audit"))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)
        #expect(throws: AgenticEvaluation.EvaluationError.emptyReport) {
            _ = try AgenticEvaluation.saveReport("  ", agentName: "codex", in: dir)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == saved)
    }

    @Test func prepareThrowsWhenSessionHasNoTraffic() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: AgenticEvaluation.EvaluationError.noTraffic) {
            try AgenticEvaluation.prepare(sessionDir: dir)
        }
        // No transcript file is left behind on the empty-traffic path.
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(AgenticEvaluation.transcriptFilename).path))
    }

    @Test func preparePreservesMalformedOnlyTrafficAsUnavailableEvidence() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{truncated\n".utf8).write(
            to: dir.appendingPathComponent(BrainTrafficLog.filename))
        try Data().write(to: dir.appendingPathComponent(ActivityLog.filename))

        _ = try AgenticEvaluation.prepare(sessionDir: dir)

        let transcript = try String(
            contentsOf: dir.appendingPathComponent(AgenticEvaluation.transcriptFilename),
            encoding: .utf8)
        #expect(transcript.contains("malformed traffic entry"))
        #expect(transcript.contains("total unavailable"))
    }

    @Test func prepareRequiresTheCompleteActivityFile() throws {
        let dir = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let traffic = BrainTrafficLog(); traffic.enable(directory: dir)
        traffic.record(tag: "coach",
                       request: Data(#"{"model":"gpt-5.5","input":[]}"#.utf8),
                       response: Data(#"{"status":"completed","output":[]}"#.utf8),
                       status: 200, latencyMs: 300)
        traffic.flush()

        #expect(throws: AgenticEvaluation.EvaluationError.missingActivityLog) {
            try AgenticEvaluation.prepare(sessionDir: dir)
        }
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
        traffic.flush()
        try Data().write(to: dir.appendingPathComponent(ActivityLog.filename))
        // A directory squatting on the transcript path makes createFile fail.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(AgenticEvaluation.transcriptFilename),
            withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try AgenticEvaluation.prepare(sessionDir: dir)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter {
                $0.hasPrefix(".\(AgenticEvaluation.transcriptFilename).")
                    && $0.hasSuffix(".tmp")
            }
        #expect(leftovers.isEmpty)
    }
}
