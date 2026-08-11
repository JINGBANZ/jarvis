import Foundation

/// Evaluator-facing completeness status for the versioned session-audit format.
struct SessionAuditEvidence: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case complete
        case partial
        case legacy
    }

    let state: State
    let limitations: [String]

    static let legacy = SessionAuditEvidence(state: .legacy, limitations: [])

    var isPartial: Bool { state == .partial }

    var summary: String {
        switch state {
        case .complete:
            "Session audit evidence: complete."
        case .legacy:
            "Session audit evidence: historical format without a completion marker."
        case .partial:
            "WARNING: session audit evidence is partial (\(limitations.joined(separator: "; "))); audit-derived counts below are known evidence, not exact session totals."
        }
    }

    static func assess(
        trafficJSONL: String,
        attemptsJSONL: String?,
        healthJSON: String?
    ) -> SessionAuditEvidence {
        let trafficRecords = JSONLRecords.parse(trafficJSONL)
        let attemptRecords = attemptsJSONL.map(JSONLRecords.parse)
        let newFormat = trafficRecords.objects.contains(where: {
            ($0["audit_version"] as? Int) == FileSessionAudit.formatVersion
        }) || (attemptRecords?.objects.contains(where: {
            ($0["audit_version"] as? Int) == FileSessionAudit.formatVersion
        }) ?? false)

        var limitations: [String] = []
        if let healthJSON {
            if let data = healthJSON.data(using: .utf8),
               let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               marker["version"] as? Int == FileSessionAudit.formatVersion,
               let state = marker["state"] as? String {
                if state == "in_progress" || state == "open" {
                    limitations.append("session close incomplete")
                } else if state == "partial" {
                    limitations.append("health marker reports partial evidence")
                } else if state != "complete" {
                    limitations.append("health marker state \(state) unsupported")
                }
                for (key, label) in [
                    ("queue_overflow", "queue overflow"),
                    ("oversize_record", "oversize record"),
                    ("open_failure", "open failure"),
                    ("write_failure", "write failure"),
                    ("serialization_failure", "serialization failure"),
                ] {
                    guard let count = marker[key] as? Int, count >= 0 else {
                        limitations.append("health marker field \(key) missing or invalid")
                        continue
                    }
                    if count > 0 {
                        limitations.append("\(label): \(count)")
                    }
                }
            } else {
                limitations.append("health marker malformed or unsupported")
            }
        } else if newFormat {
            limitations.append("completion marker missing")
        } else {
            return .legacy
        }
        if trafficRecords.malformedCount > 0 {
            limitations.append("malformed traffic: \(trafficRecords.malformedCount)")
        }
        if attemptsJSONL == nil {
            limitations.append("coaching-attempt evidence missing")
        } else if let malformed = attemptRecords?.malformedCount, malformed > 0 {
            limitations.append("malformed coaching attempts: \(malformed)")
        }

        return limitations.isEmpty
            ? SessionAuditEvidence(state: .complete, limitations: [])
            : SessionAuditEvidence(state: .partial, limitations: limitations)
    }
}
