import Foundation

/// Deterministic transcription/trigger accounting for the evaluator. Causal counts come only from
/// first-class coaching provenance; older sessions render those fields as unavailable rather than
/// inviting the auditor to infer them from transcript prose or `stay_silent` volume.
enum TriggerQualityMetrics {
    private struct TranscriptEvidence {
        let classification: String
        let brainFacing: Bool
    }

    static func render(
        trafficJSONL: String,
        attemptsJSONL: String?,
        activityJSONL: String?,
        auditEvidence: SessionAuditEvidence = .legacy
    ) -> String {
        let trafficRecords = JSONLRecords.parse(trafficJSONL)
        let trafficMalformed = trafficRecords.malformedCount
        let trafficEntries = trafficRecords.objects.filter { $0["request"] != nil }
        let calls = trafficEntries.filter(isProviderCall)
        let coachCalls = calls.filter { ($0["tag"] as? String) == "coach" }
        let coachPreRequestFailures = trafficEntries.count(where: {
            ($0["tag"] as? String) == "coach" && !isProviderCall($0)
        })
        let calledAttemptIDs = Set(coachCalls.compactMap {
            ($0["coach_attempt"] as? [String: Any])?["id"] as? Int
        })
        let unavailableCallJoins = trafficMalformed + coachCalls.count(where: {
            (($0["coach_attempt"] as? [String: Any])?["id"] as? Int) == nil
        })
        let attemptRecords = attemptsJSONL.map(JSONLRecords.parse)
        let attemptEvents = attemptRecords?.objects
        let recognizedAttemptEvents = attemptEvents?.filter {
            $0["attempt"] as? Int != nil
                && (($0["event"] as? String) == "started"
                    || ($0["event"] as? String) == "finished")
        } ?? []
        let attemptUnavailableRecords = (attemptRecords?.malformedCount ?? 0)
            + ((attemptEvents?.count ?? 0) - recognizedAttemptEvents.count)
        let attemptsAvailable = attemptsJSONL != nil
            && (!recognizedAttemptEvents.isEmpty
                || ((attemptRecords?.lines.isEmpty ?? false) && coachCalls.isEmpty))

        var triggerCounts: [String: Int] = [:]
        var phaseCounts: [String: Int] = [:]
        var unavailableTriggerCalls = 0
        var unavailablePhaseCalls = 0
        for call in coachCalls {
            guard let provenance = call["coach_attempt"] as? [String: Any] else {
                unavailableTriggerCalls += 1
                unavailablePhaseCalls += 1
                continue
            }
            if let trigger = provenance["trigger"] as? String {
                triggerCounts[trigger, default: 0] += 1
            } else {
                unavailableTriggerCalls += 1
            }
            if let phase = provenance["phase"] as? String {
                phaseCounts[phase, default: 0] += 1
            } else {
                unavailablePhaseCalls += 1
            }
        }

        var evidenceByIndex: [Int: TranscriptEvidence] = [:]
        var skippedFillerTurns = 0
        var attemptStaySilent = 0
        var startedAttemptIDs: Set<Int> = []
        var finishedAttemptIDs: Set<Int> = []
        if attemptsAvailable {
            for event in recognizedAttemptEvents {
                let attemptID = event["attempt"] as? Int ?? -1
                switch event["event"] as? String {
                case "started":
                    startedAttemptIDs.insert(attemptID)
                    for line in event["transcript"] as? [[String: Any]] ?? [] {
                        guard let index = line["index"] as? Int,
                              let classification = line["classification"] as? String
                        else { continue }
                        // A failed attempt can expose the same uncommitted line again. Keep the
                        // strongest evidence: reaching the brain in any attempt is what matters.
                        let candidate = TranscriptEvidence(
                            classification: classification,
                            brainFacing: (line["brain_facing"] as? Bool ?? false)
                                && calledAttemptIDs.contains(attemptID))
                        if let current = evidenceByIndex[index], current.brainFacing {
                            continue
                        }
                        evidenceByIndex[index] = candidate
                    }
                case "finished":
                    finishedAttemptIDs.insert(attemptID)
                    switch event["terminal"] as? String {
                    case CoachingAttemptAuditEvent.TerminalAction.skippedFiller.rawValue:
                        skippedFillerTurns += 1
                    case CoachingAttemptAuditEvent.TerminalAction.staySilent.rawValue:
                        attemptStaySilent += 1
                    default:
                        break
                    }
                default:
                    continue
                }
            }
        }

        let activityRecords = activityJSONL.map(JSONLRecords.parse)
        let activityKinds = activityRecords.map { records in
            records.objects.compactMap { $0["k"] as? String }
        }
        let activityUnavailableRecords = (activityRecords?.malformedCount ?? 0)
            + ((activityRecords?.objects.count ?? 0) - (activityKinds?.count ?? 0))
        let heardCount = activityKinds.map { kinds in
            kinds.count(where: { $0 == ActivityLog.EventKind.heard.rawValue })
        }
        let activityStaySilent = activityKinds.map { kinds in
            kinds.count(where: { $0 == ActivityLog.EventKind.stayedSilent.rawValue })
        }
        let classifiedCount = evidenceByIndex.count
        let unfinishedAttempts = startedAttemptIDs.subtracting(finishedAttemptIDs).count
        let knownFillerCount = evidenceByIndex.values.count(where: {
            $0.classification == TurnSubstance.Classification.knownFiller.rawValue
                || $0.classification == TurnSubstance.Classification.compositeFiller.rawValue
        })
        let compositeMisses = evidenceByIndex.values.count(where: {
            $0.classification == TurnSubstance.Classification.compositeFiller.rawValue
                && $0.brainFacing
        })

        var lines: [String] = [
            "=== transcription and trigger quality (computed; do NOT infer causality from prose) ===",
            auditEvidence.summary,
        ]
        if trafficMalformed + attemptUnavailableRecords + activityUnavailableRecords > 0 {
            lines.append(
                "Evidence warning: malformed or unrecognized JSONL records are unavailable evidence, not zeros; affected values below are explicitly partial.")
        }
        let preRequestFailureValue = knownValue(
            coachPreRequestFailures,
            limitations: auditEvidence.limitations + (trafficMalformed == 0
                ? []
                : ["\(trafficMalformed) malformed traffic record(s)"]))
        lines += [
            "",
            "| measure | value |",
            "|---|---:|",
            "| finalized heard lines | \(activityValue(heardCount, unavailableRecords: activityUnavailableRecords)) |",
            "| known filler lines | \(classifiedValue(knownFillerCount, classified: classifiedCount, heard: heardCount, attemptsAvailable: attemptsAvailable, unavailableRecords: attemptUnavailableRecords, auditLimitations: auditEvidence.limitations)) |",
            "| filler-only turn ends skipped before a provider call | \(terminalValue(skippedFillerTurns, unfinished: unfinishedAttempts, attemptsAvailable: attemptsAvailable, unavailableRecords: attemptUnavailableRecords, auditLimitations: auditEvidence.limitations)) |",
            "| composite-filler misses that reached the brain | \(classifiedValue(compositeMisses, classified: classifiedCount, heard: heardCount, attemptsAvailable: attemptsAvailable, unavailableRecords: attemptUnavailableRecords, unavailableCallJoins: unavailableCallJoins, auditLimitations: auditEvidence.limitations)) |",
            "| model `stay_silent` decisions | \(activityStaySilent.map { activityValue($0, unavailableRecords: activityUnavailableRecords) } ?? terminalValue(attemptStaySilent, unfinished: unfinishedAttempts, attemptsAvailable: attemptsAvailable, unavailableRecords: attemptUnavailableRecords, auditLimitations: auditEvidence.limitations)) |",
            "| CLI setup/pre-request failures before a provider call | \(preRequestFailureValue) |",
            "",
            "`stay_silent` is a terminal model-decision count, never an avoidable-call count.",
            "",
            "provider calls by trigger reason:",
            "| trigger | known calls |",
            "|---|--:|",
        ]
        for (key, label) in [
            ("turn_end", "turn end"),
            ("silence", "silence"),
            ("manual_hint", "manual hint"),
            ("pending_work", "pending-work wake"),
        ] {
            lines.append("| \(label) | \(knownValue(triggerCounts[key, default: 0], limitations: auditEvidence.limitations)) |")
        }
        if unavailableTriggerCalls > 0 {
            lines.append("| unavailable | \(unavailableTriggerCalls) |")
        }
        if trafficMalformed > 0 {
            lines.append("| malformed traffic record (call type unavailable) | \(trafficMalformed) |")
        }

        lines += [
            "",
            "coach-call phase:",
            "| phase | known calls |",
            "|---|--:|",
            "| initial coaching request | \(knownValue(phaseCounts[CoachingAttemptAuditEvent.RequestPhase.initial.rawValue, default: 0], limitations: auditEvidence.limitations)) |",
            "| `capture_screen` continuation | \(knownValue(phaseCounts[CoachingAttemptAuditEvent.RequestPhase.captureScreenContinuation.rawValue, default: 0], limitations: auditEvidence.limitations)) |",
        ]
        if unavailablePhaseCalls > 0 {
            lines.append("| unavailable | \(unavailablePhaseCalls) |")
        }
        if trafficMalformed > 0 {
            lines.append("| malformed traffic record (phase unavailable) | \(trafficMalformed) |")
        }

        let metricCalls = SessionMetrics.parse(jsonl: trafficJSONL).filter {
            $0.recordKind == .providerCall
        }
        lines += [
            "",
            "telemetry availability (all provider calls):",
            "| field | known calls | unavailable calls |",
            "|---|--:|--:|",
            availabilityRow("input tokens", values: metricCalls.map(\.input), auditLimitations: auditEvidence.limitations),
            availabilityRow("cache read", values: metricCalls.map(\.cacheRead), auditLimitations: auditEvidence.limitations),
            availabilityRow("cache write", values: metricCalls.map(\.cacheWrite), auditLimitations: auditEvidence.limitations),
            availabilityRow("output tokens", values: metricCalls.map(\.output), auditLimitations: auditEvidence.limitations),
            availabilityRow("cost", values: metricCalls.map(\.cost), auditLimitations: auditEvidence.limitations),
        ]
        if trafficMalformed > 0 {
            lines.append(
                "\(trafficMalformed) malformed traffic record(s) could not be classified; telemetry totals are partial.")
        }
        return lines.joined(separator: "\n")
    }

    private static func classifiedValue(
        _ value: Int,
        classified: Int,
        heard: Int?,
        attemptsAvailable: Bool,
        unavailableRecords: Int,
        unavailableCallJoins: Int = 0,
        auditLimitations: [String] = []
    ) -> String {
        guard attemptsAvailable else { return "—" }
        var limitations = auditLimitations
        guard let heard else {
            limitations.append("total heard unavailable")
            if unavailableRecords > 0 {
                limitations.append("\(unavailableRecords) unavailable attempt record(s)")
            }
            if unavailableCallJoins > 0 {
                limitations.append("\(unavailableCallJoins) unavailable traffic join(s)")
            }
            return knownValue(value, limitations: limitations)
        }
        let unavailable = max(0, heard - classified)
        if unavailable > 0 { limitations.append("\(unavailable) heard line(s) unclassified") }
        if unavailableRecords > 0 {
            limitations.append("\(unavailableRecords) unavailable attempt record(s)")
        }
        if unavailableCallJoins > 0 {
            limitations.append("\(unavailableCallJoins) unavailable traffic join(s)")
        }
        return knownValue(value, limitations: limitations)
    }

    private static func availabilityRow<T>(
        _ name: String,
        values: [T?],
        auditLimitations: [String] = []
    ) -> String {
        let known = values.compactMap { $0 }.count
        guard auditLimitations.isEmpty else {
            return "| \(name) | \(known) known | \(values.count - known) known unavailable; session total unavailable |"
        }
        return "| \(name) | \(known) | \(values.count - known) |"
    }

    private static func terminalValue(
        _ value: Int,
        unfinished: Int,
        attemptsAvailable: Bool,
        unavailableRecords: Int,
        auditLimitations: [String] = []
    ) -> String {
        guard attemptsAvailable else { return "—" }
        var limitations = auditLimitations
        if unfinished > 0 { limitations.append("\(unfinished) unfinished attempt(s)") }
        if unavailableRecords > 0 {
            limitations.append("\(unavailableRecords) unavailable attempt record(s)")
        }
        return knownValue(value, limitations: limitations)
    }

    private static func activityValue(_ value: Int?, unavailableRecords: Int) -> String {
        guard let value else { return "—" }
        let limitations = unavailableRecords == 0
            ? []
            : ["\(unavailableRecords) unavailable Activity record(s)"]
        return knownValue(value, limitations: limitations)
    }

    private static func knownValue(_ value: Int, limitations: [String]) -> String {
        limitations.isEmpty ? String(value) : "\(value) known (\(limitations.joined(separator: "; ")))"
    }

    private static func isProviderCall(_ entry: [String: Any]) -> Bool {
        entry["record_kind"] as? String
            != BrainTrafficAuditEvent.Kind.preRequestFailure.rawValue
    }
}
