import Foundation

/// A neutral inventory of the persisted inputs available to the session evaluator. It exposes
/// record health, categorical distributions, and correlation-field coverage without encoding an
/// opinion about which combinations are correct or which incidents the evaluator should find.
enum SessionEvidenceIndex {
    private struct Dimension {
        let source: String
        let field: String
        let values: [String?]
    }

    static func render(
        trafficJSONL: String,
        attemptsJSONL: String?,
        activityJSONL: String?,
        healthJSON: String?,
        auditEvidence: SessionAuditEvidence
    ) -> String {
        let traffic = JSONLRecords.parse(trafficJSONL)
        let attempts = attemptsJSONL.map(JSONLRecords.parse)
        let activity = activityJSONL.map(JSONLRecords.parse)
        let trafficRows = traffic.objects
        let attemptRows = attempts?.objects ?? []
        let activityRows = activity?.objects ?? []
        let transcriptRows = attemptRows.flatMap {
            $0["transcript"] as? [[String: Any]] ?? []
        }
        let coachTrafficRows = trafficRows.filter { ($0["tag"] as? String) == "coach" }

        var lines = [
            "=== session evidence index (computed; descriptive, not diagnostic) ===",
            auditEvidence.summary,
            "The tables below inventory recorded evidence. A distribution or missing field is not, by itself, a finding.",
            "",
            "artifact inventory:",
            "| artifact | availability | valid JSON records | malformed JSON records |",
            "|---|---|--:|--:|",
            jsonlArtifactRow(
                filename: FileSessionAudit.brainTrafficFilename,
                contents: trafficJSONL,
                parsed: traffic),
            jsonlArtifactRow(
                filename: FileSessionAudit.coachingAttemptsFilename,
                contents: attemptsJSONL,
                parsed: attempts),
            jsonlArtifactRow(
                filename: ActivityLog.filename,
                contents: activityJSONL,
                parsed: activity),
            jsonArtifactRow(filename: FileSessionAudit.healthFilename, contents: healthJSON),
            "",
            "categorical distributions:",
            "| source | field | observed values | field coverage |",
            "|---|---|---|---:|",
        ]

        var dimensions = [
            dimension(FileSessionAudit.brainTrafficFilename, "record_kind", trafficRows),
            dimension(FileSessionAudit.brainTrafficFilename, "tag", trafficRows),
            dimension(FileSessionAudit.brainTrafficFilename, "status", trafficRows),
            dimension(FileSessionAudit.brainTrafficFilename, "request.model", trafficRows),
            dimension(FileSessionAudit.brainTrafficFilename, "coach_attempt.trigger", trafficRows),
            dimension(FileSessionAudit.brainTrafficFilename, "coach_attempt.source_trigger", trafficRows),
            dimension(FileSessionAudit.brainTrafficFilename, "coach_attempt.phase", trafficRows),
        ]
        if attemptsJSONL != nil {
            dimensions += [
                dimension(FileSessionAudit.coachingAttemptsFilename, "event", attemptRows),
                dimension(FileSessionAudit.coachingAttemptsFilename, "wake", attemptRows),
                dimension(FileSessionAudit.coachingAttemptsFilename, "trigger", attemptRows),
                dimension(FileSessionAudit.coachingAttemptsFilename, "source_trigger", attemptRows),
                dimension(FileSessionAudit.coachingAttemptsFilename, "provider", attemptRows),
                dimension(FileSessionAudit.coachingAttemptsFilename, "model", attemptRows),
                dimension(FileSessionAudit.coachingAttemptsFilename, "terminal", attemptRows),
                dimension(FileSessionAudit.coachingAttemptsFilename, "outcome", attemptRows),
                dimension("attempt transcript entries", "speaker", transcriptRows),
                dimension("attempt transcript entries", "classification", transcriptRows),
                dimension("attempt transcript entries", "brain_facing", transcriptRows),
            ]
        }
        if activityJSONL != nil {
            dimensions.append(dimension(ActivityLog.filename, "k", activityRows))
        }
        lines += dimensions.map(renderDimension)

        lines += [
            "",
            "correlation-field coverage:",
            "| source | field | field coverage |",
            "|---|---|---:|",
            coverageRow(FileSessionAudit.brainTrafficFilename, "t", trafficRows),
            coverageRow("coach traffic records", "coach_attempt.id", coachTrafficRows),
        ]
        if attemptsJSONL != nil {
            lines += [
                coverageRow(FileSessionAudit.coachingAttemptsFilename, "t", attemptRows),
                coverageRow(FileSessionAudit.coachingAttemptsFilename, "attempt", attemptRows),
                coverageRow("attempt transcript entries", "index", transcriptRows),
                coverageRow("attempt transcript entries", "at", transcriptRows),
            ]
        }
        if activityJSONL != nil {
            lines += [
                coverageRow(ActivityLog.filename, "t", activityRows),
                coverageRow(ActivityLog.filename, "o", activityRows),
                coverageRow(ActivityLog.filename, "q", activityRows),
                coverageRow(ActivityLog.filename, "r", activityRows),
            ]
        }
        lines += [
            "",
            "Coverage denominators include valid rows only; malformed rows remain visible in the artifact inventory.",
            "JSONL record numbers are one-based nonblank-line anchors. Traffic `call #N` uses the same N; raw attempt ids and transcript indices remain available for joins.",
        ]
        return lines.joined(separator: "\n")
    }

    private static func jsonlArtifactRow(
        filename: String,
        contents: String?,
        parsed: JSONLRecords.Parsed?
    ) -> String {
        guard contents != nil, let parsed else {
            return "| `\(filename)` | missing | — | — |"
        }
        return "| `\(filename)` | present | \(parsed.objects.count) | \(parsed.malformedCount) |"
    }

    private static func jsonArtifactRow(filename: String, contents: String?) -> String {
        guard let contents else { return "| `\(filename)` | missing | — | — |" }
        guard let data = contents.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return "| `\(filename)` | present | 0 | 1 |" }
        return "| `\(filename)` | present | 1 | 0 |"
    }

    private static func dimension(
        _ source: String,
        _ field: String,
        _ rows: [[String: Any]]
    ) -> Dimension {
        Dimension(source: source, field: field, values: rows.map { scalar(at: field, in: $0) })
    }

    private static func renderDimension(_ dimension: Dimension) -> String {
        let known = dimension.values.compactMap { $0 }
        var counts: [String: Int] = [:]
        for value in known { counts[value, default: 0] += 1 }
        let distribution = counts.keys.sorted().map {
            "\(markdownCell($0)): \(counts[$0]!)"
        }.joined(separator: ", ")
        return "| \(dimension.source) | `\(dimension.field)` | \(distribution.isEmpty ? "—" : distribution) | \(coverage(known: known.count, total: dimension.values.count)) |"
    }

    private static func coverageRow(
        _ source: String,
        _ field: String,
        _ rows: [[String: Any]]
    ) -> String {
        let known = rows.count(where: { scalar(at: field, in: $0) != nil })
        return "| \(source) | `\(field)` | \(coverage(known: known, total: rows.count)) |"
    }

    private static func coverage(known: Int, total: Int) -> String {
        total == 0 ? "no rows" : "\(known)/\(total)"
    }

    private static func scalar(at path: String, in row: [String: Any]) -> String? {
        var value: Any = row
        for component in path.split(separator: ".").map(String.init) {
            guard let object = value as? [String: Any], let next = object[component] else {
                return nil
            }
            value = next
        }
        if let string = value as? String { return string }
        if let bool = value as? Bool { return String(bool) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func markdownCell(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
