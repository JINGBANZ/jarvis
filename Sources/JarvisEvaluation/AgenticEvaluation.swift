import Foundation
import JarvisBrainProviders
import JarvisCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum AgenticEvaluation {
    /// The agent reads the transcript from this file rather than from a giant argv.
    public static let transcriptFilename = "eval-transcript.txt"

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

    /// A cheap preflight: a non-empty file may still hold no valid records; `prepare` decides.
    public static func hasTraffic(in sessionDir: URL) -> Bool {
        let url = sessionDir.appendingPathComponent(FileSessionAudit.brainTrafficFilename)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    public static func savedReport(in sessionDir: URL) -> String? {
        let url = sessionDir.appendingPathComponent(reportFilename)
        guard let report = try? String(contentsOf: url, encoding: .utf8), !report.isEmpty
        else { return nil }
        return report
    }

    /// Writes the transcript into the session directory and returns the CLI's task prompt.
    public static func prepare(sessionDir: URL, workspaceProvenance: String) throws -> String {
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

        // A failed write must abort: the prompt names the transcript as the agent's primary input.
        try replaceOwnerOnlyFile(
            Data(transcript.utf8), filename: transcriptFilename, in: sessionDir)

        return prompt(sessionDirPath: sessionDir.path, workspaceProvenance: workspaceProvenance)
    }

    static func saveReport(_ markdown: String, agentName: String, in sessionDir: URL,
                           workspaceProvenance: String? = nil) throws -> String {
        let body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw EvaluationError.emptyReport }
        let stamp = """
            > _Produced by the agentic evaluator (`\(agentName)` over the repo + session); the auditor \
            was instructed to separate observed evidence, source-confirmed facts, and hypotheses._
            """
        let sourceStamp = workspaceProvenance.map { "\n\n> \($0)" } ?? ""
        let report = "\(stamp)\(sourceStamp)\n\n\(body)\n"
        try replaceOwnerOnlyFile(
            Data(report.utf8), filename: reportFilename, in: sessionDir)
        return report
    }

    private static func replaceOwnerOnlyFile(
        _ data: Data, filename: String, in sessionDir: URL
    ) throws {
        let destination = sessionDir.appendingPathComponent(filename)
        let temporary = sessionDir.appendingPathComponent(
            ".\(filename).\(UUID().uuidString).tmp")
        // `createFile` can fail after writing a partial file, so always remove the temporary path.
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }

        // POSIX rename installs the fresh 0600 inode. Foundation's `replaceItemAt` may keep an
        // existing destination's looser mode.
        guard rename(temporary.path, destination.path) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            throw error
        }
    }

    static func prompt(sessionDirPath: String, workspaceProvenance: String) -> String {
        JarvisPrompts.Evaluation.sessionAudit(
            sessionDirectoryPath: sessionDirPath,
            transcriptFilename: transcriptFilename,
            trafficFilename: FileSessionAudit.brainTrafficFilename,
            attemptsFilename: FileSessionAudit.coachingAttemptsFilename,
            healthFilename: FileSessionAudit.healthFilename,
            activityFilename: ActivityLog.filename,
            reportFilename: reportFilename,
            workspaceProvenance: workspaceProvenance
        )
    }
}
