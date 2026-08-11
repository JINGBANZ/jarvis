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

    /// Exact audit-health bytes used by the evaluator that produced `eval-report.md`. Activity only
    /// discovers a versioned report while this stamp still matches the canonical health evidence.
    public static let reportEvidenceFilename = "eval-report.evidence"

    public enum EvaluationError: LocalizedError, Equatable {
        case noTraffic
        case missingActivityLog
        case emptyReport
        case evidenceChanged

        public var errorDescription: String? {
            switch self {
            case .noTraffic:
                "No brain traffic was recorded for this session — nothing to evaluate."
            case .missingActivityLog:
                "The session's complete Activity log is missing or unreadable."
            case .emptyReport:
                "The agentic evaluator returned an empty report."
            case .evidenceChanged:
                "This session's audit evidence changed during evaluation. Wait for it to settle, then try again."
            }
        }
    }

    /// A cheap UI preflight. `prepare` remains the authoritative parser because a non-empty file may
    /// still contain no valid traffic records.
    public static func hasTraffic(in sessionDir: URL) -> Bool {
        let url = sessionDir.appendingPathComponent(FileSessionAudit.brainTrafficFilename)
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
        let evidenceURL = sessionDir.appendingPathComponent(reportEvidenceFilename)
        if let recordedEvidence = try? Data(contentsOf: evidenceURL) {
            guard let currentEvidence = try? evidenceStamp(in: sessionDir),
                  recordedEvidence == currentEvidence
            else { return nil }
        } else if usesVersionedAudit(in: sessionDir) {
            // Reports from legacy sessions predate evidence stamps and remain static. A report beside
            // the new versioned audit format must carry provenance or it cannot be trusted.
            return nil
        }
        return report
    }

    /// Remove every evaluator-derived view of a session. Audit evidence can become partial again
    /// after a late observer call, so a transcript or report produced under the earlier complete
    /// marker must not be offered as current. `unlink` keeps this narrowly file-only and idempotent.
    public static func invalidateDerivedArtifacts(in sessionDir: URL) throws {
        let filenames = [
            transcriptFilename,
            reportFilename,
            reportEvidenceFilename,
            EvalReportPage.filename,
        ]
        var firstError: Error?
        for filename in filenames {
            let path = sessionDir.appendingPathComponent(filename).path
            guard unlink(path) != 0 else { continue }
            let code = errno
            guard code != ENOENT else { continue }
            if firstError == nil {
                firstError = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        }
        if let firstError { throw firstError }
    }

    /// Snapshot the canonical evidence marker without hashing or copying the larger traffic logs.
    /// Atomic marker replacement means exact bytes distinguish the complete/partial generation; the
    /// leading byte distinguishes a genuinely missing marker from an empty file.
    static func evidenceStamp(in sessionDir: URL) throws -> Data {
        let url = sessionDir.appendingPathComponent(FileSessionAudit.healthFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return Data([0]) }
        var stamp = Data([1])
        stamp.append(try Data(contentsOf: url))
        return stamp
    }

    private static func usesVersionedAudit(in sessionDir: URL) -> Bool {
        let healthURL = sessionDir.appendingPathComponent(FileSessionAudit.healthFilename)
        if FileManager.default.fileExists(atPath: healthURL.path) { return true }
        let trafficURL = sessionDir.appendingPathComponent(FileSessionAudit.brainTrafficFilename)
        guard let handle = try? FileHandle(forReadingFrom: trafficURL) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 4_096) else { return false }
        // The worker serializes sorted keys, so `audit_version` is in this bounded prefix even when
        // the request body makes the first JSONL record large.
        return String(decoding: prefix, as: UTF8.self).contains(
            "\"audit_version\":\(FileSessionAudit.formatVersion)")
    }

    /// Prepare the agent's workspace for one session and return the task prompt to feed the CLI.
    ///
    /// Renders the session's recorded traffic to the compact transcript, writes it owner-only into the
    /// session directory, and returns the prompt (which embeds the directory's absolute path so the
    /// agent knows where its inputs live). Throws `EvaluationError.noTraffic` when there is nothing
    /// to audit.
    public static func prepare(sessionDir: URL) throws -> String {
        try CodexRuntimeHome.removeLegacyHomes(from: sessionDir)
        let trafficURL = sessionDir.appendingPathComponent(FileSessionAudit.brainTrafficFilename)
        let jsonl = (try? String(contentsOf: trafficURL, encoding: .utf8)) ?? ""
        guard !JSONLRecords.parse(jsonl).lines.isEmpty else {
            throw EvaluationError.noTraffic
        }
        let activityURL = sessionDir.appendingPathComponent(ActivityLog.filename)
        guard FileManager.default.isReadableFile(atPath: activityURL.path) else {
            throw EvaluationError.missingActivityLog
        }
        let activityJSONL = try String(contentsOf: activityURL, encoding: .utf8)
        let attemptsURL = sessionDir.appendingPathComponent(FileSessionAudit.coachingAttemptsFilename)
        let attemptsJSONL = try? String(contentsOf: attemptsURL, encoding: .utf8)
        let healthURL = sessionDir.appendingPathComponent(FileSessionAudit.healthFilename)
        let healthJSON = try? String(contentsOf: healthURL, encoding: .utf8)
        let transcript = EvaluationTranscript.render(
            jsonl: jsonl,
            attemptsJSONL: attemptsJSONL,
            activityJSONL: activityJSONL,
            healthJSON: healthJSON)
        guard !transcript.isEmpty else { throw EvaluationError.noTraffic }

        // A failed write must abort: the prompt tells the agent the transcript is its primary
        // input, so silently proceeding would spend a whole agentic run on a missing/stale file.
        try replaceOwnerOnlyFile(
            Data(transcript.utf8), filename: transcriptFilename, in: sessionDir)

        return prompt(sessionDirPath: sessionDir.path)
    }

    /// Persist one successful agent result without ever exposing report bytes through a permissive
    /// intermediate file. A failed run never reaches this point, so an older report remains intact.
    static func saveReport(
        _ markdown: String,
        agentName: String,
        evidenceStamp: Data? = nil,
        in sessionDir: URL
    ) throws -> String {
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
        try replaceOwnerOnlyFile(
            evidenceStamp ?? Self.evidenceStamp(in: sessionDir),
            filename: reportEvidenceFilename,
            in: sessionDir)
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
            trafficFilename: FileSessionAudit.brainTrafficFilename,
            attemptsFilename: FileSessionAudit.coachingAttemptsFilename,
            healthFilename: FileSessionAudit.healthFilename,
            activityFilename: ActivityLog.filename,
            reportFilename: reportFilename
        )
    }
}
