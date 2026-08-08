import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The session audit hands a complete session to an agentic CLI (Claude Code / Codex) whose workspace
/// is the repo checkout **plus** the session directory. The auditor can read the harness's code, the
/// compact wire transcript, the complete raw traffic, the complete Activity log, and screenshots,
/// then verifies each finding against the actual implementation instead of guessing from one input.
///
/// This type renders the traffic to a compact, delta-aware transcript, writes that derived view beside
/// the untouched source logs as an owner-only file, and assembles the task prompt that points the CLI
/// at every input. `AgenticEvaluator` owns the process invocation so the app's Evaluate button and the
/// dev-side script share the same read-only agentic workflow.
public enum AgenticEvaluation {
    /// The rendered transcript is written here (owner-only) so the agent reads a file, not a giant
    /// argv. Sits beside `brain-traffic.jsonl` and `eval-report.md` in the session dir.
    public static let transcriptFilename = "eval-transcript.txt"

    /// The audit report the agent writes back. Activity opens it after the agentic run.
    public static let reportFilename = "eval-report.md"

    public enum EvaluationError: LocalizedError, Equatable {
        case noTraffic
        case missingActivityLog
        case emptyReport

        public var errorDescription: String? {
            switch self {
            case .noTraffic:
                "No brain traffic was recorded for this session — nothing to evaluate."
            case .missingActivityLog:
                "The session's complete Activity log is missing or unreadable."
            case .emptyReport:
                "The agentic evaluator returned an empty report."
            }
        }
    }

    /// A cheap UI preflight. `prepare` remains the authoritative parser because a non-empty file may
    /// still contain no valid traffic records.
    public static func hasTraffic(in sessionDir: URL) -> Bool {
        let url = sessionDir.appendingPathComponent(BrainTrafficLog.filename)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    /// The report persisted by an earlier agentic audit, if any.
    public static func savedReport(in sessionDir: URL) -> String? {
        let url = sessionDir.appendingPathComponent(reportFilename)
        guard let report = try? String(contentsOf: url, encoding: .utf8), !report.isEmpty
        else { return nil }
        return report
    }

    /// Prepare the agent's workspace for one session and return the task prompt to feed the CLI.
    ///
    /// Renders the session's recorded traffic to the compact transcript, writes it owner-only into the
    /// session directory, and returns the prompt (which embeds the directory's absolute path so the
    /// agent knows where its inputs live). Throws `EvaluationError.noTraffic` when there is nothing
    /// to audit.
    public static func prepare(sessionDir: URL) throws -> String {
        try CodexRuntimeHome.removeLegacyHomes(from: sessionDir)
        let trafficURL = sessionDir.appendingPathComponent(BrainTrafficLog.filename)
        let jsonl = (try? String(contentsOf: trafficURL, encoding: .utf8)) ?? ""
        guard !SessionMetrics.parse(jsonl: jsonl).isEmpty else {
            throw EvaluationError.noTraffic
        }
        let activityURL = sessionDir.appendingPathComponent(ActivityLog.filename)
        guard FileManager.default.isReadableFile(atPath: activityURL.path) else {
            throw EvaluationError.missingActivityLog
        }
        let activityJSONL = try String(contentsOf: activityURL, encoding: .utf8)
        let attemptsURL = sessionDir.appendingPathComponent(CoachingAttemptLog.filename)
        let attemptsJSONL = try? String(contentsOf: attemptsURL, encoding: .utf8)
        let transcript = EvaluationTranscript.render(
            jsonl: jsonl,
            attemptsJSONL: attemptsJSONL,
            activityJSONL: activityJSONL)
        guard !transcript.isEmpty else { throw EvaluationError.noTraffic }

        // A failed write must abort: the prompt tells the agent the transcript is its primary
        // input, so silently proceeding would spend a whole agentic run on a missing/stale file.
        try replaceOwnerOnlyFile(
            Data(transcript.utf8), filename: transcriptFilename, in: sessionDir)

        return prompt(sessionDirPath: sessionDir.path)
    }

    /// Persist one successful agent result without ever exposing report bytes through a permissive
    /// intermediate file. A failed run never reaches this point, so an older report remains intact.
    static func saveReport(_ markdown: String, agentName: String, in sessionDir: URL) throws -> String {
        let body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw EvaluationError.emptyReport }
        let stamp = """
            > _Produced by the agentic evaluator (`\(agentName)` over the repo + session); the auditor \
            was instructed to separate session evidence, source-confirmed mechanisms, hypotheses, and \
            behavior to preserve._
            """
        let report = "\(stamp)\n\n\(body)\n"
        try replaceOwnerOnlyFile(
            Data(report.utf8), filename: reportFilename, in: sessionDir)
        return report
    }

    /// Atomically install a derived evaluator artifact with owner-only permissions. Replacing on
    /// every attempt makes Evaluate retryable after a CLI/auth/network failure left the transcript
    /// behind, and using a fresh inode avoids inheriting a legacy destination's looser mode.
    private static func replaceOwnerOnlyFile(
        _ data: Data, filename: String, in sessionDir: URL
    ) throws {
        let destination = sessionDir.appendingPathComponent(filename)
        let temporary = sessionDir.appendingPathComponent(
            ".\(filename).\(UUID().uuidString).tmp")
        // `createFile` reports failure with a Bool and may have created a partial file before doing
        // so (for example, when the volume fills). Always clean the unique temporary path; after a
        // successful rename it no longer exists, so this is harmless on the success path.
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }

        // Both paths are in the session directory, so POSIX rename atomically replaces any older
        // artifact with the already-0600 inode. Foundation's replaceItemAt may retain the
        // destination's looser mode, defeating the owner-only guarantee on a legacy file.
        guard rename(temporary.path, destination.path) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            throw error
        }
    }

    /// Assemble the session-specific values consumed by the centralized audit prompt.
    static func prompt(sessionDirPath: String) -> String {
        JarvisPrompts.Evaluation.sessionAudit(
            sessionDirectoryPath: sessionDirPath,
            transcriptFilename: transcriptFilename,
            trafficFilename: BrainTrafficLog.filename,
            attemptsFilename: CoachingAttemptLog.filename,
            activityFilename: ActivityLog.filename,
            reportFilename: reportFilename
        )
    }
}
