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
        activityJSONL: String?
    ) -> String {
        let calls = trafficEntries(trafficJSONL)
        let coachCalls = calls.filter { ($0["tag"] as? String) == "coach" }
        let calledAttemptIDs = Set(coachCalls.compactMap {
            ($0["coach_attempt"] as? [String: Any])?["id"] as? Int
        })
        let attemptEvents = attemptsJSONL.map(jsonEntries)
        let recognizedAttemptEvents = attemptEvents?.filter {
            $0["attempt"] as? Int != nil
                && (($0["event"] as? String) == "started"
                    || ($0["event"] as? String) == "finished")
        } ?? []
        let attemptsAvailable = attemptsJSONL != nil
            && (coachCalls.isEmpty || !recognizedAttemptEvents.isEmpty)

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
                    case CoachingAttemptLog.TerminalAction.skippedFiller.rawValue:
                        skippedFillerTurns += 1
                    case CoachingAttemptLog.TerminalAction.staySilent.rawValue:
                        attemptStaySilent += 1
                    default:
                        break
                    }
                default:
                    continue
                }
            }
        }

        let activityKinds = activityJSONL.map { jsonEntries($0).compactMap { $0["k"] as? String } }
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
            "",
            "| measure | value |",
            "|---|---:|",
            "| finalized heard lines | \(heardCount.map(String.init) ?? "—") |",
            "| known filler lines | \(classifiedValue(knownFillerCount, classified: classifiedCount, heard: heardCount, attemptsAvailable: attemptsAvailable)) |",
            "| filler-only turn ends skipped before a provider call | \(terminalValue(skippedFillerTurns, unfinished: unfinishedAttempts, attemptsAvailable: attemptsAvailable)) |",
            "| composite-filler misses that reached the brain | \(classifiedValue(compositeMisses, classified: classifiedCount, heard: heardCount, attemptsAvailable: attemptsAvailable)) |",
            "| model `stay_silent` decisions | \(activityStaySilent.map(String.init) ?? terminalValue(attemptStaySilent, unfinished: unfinishedAttempts, attemptsAvailable: attemptsAvailable)) |",
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
            lines.append("| \(label) | \(triggerCounts[key, default: 0]) |")
        }
        if unavailableTriggerCalls > 0 {
            lines.append("| unavailable | \(unavailableTriggerCalls) |")
        }

        lines += [
            "",
            "coach-call phase:",
            "| phase | known calls |",
            "|---|--:|",
            "| initial coaching request | \(phaseCounts[CoachingAttemptLog.RequestPhase.initial.rawValue, default: 0]) |",
            "| `capture_screen` continuation | \(phaseCounts[CoachingAttemptLog.RequestPhase.captureScreenContinuation.rawValue, default: 0]) |",
        ]
        if unavailablePhaseCalls > 0 {
            lines.append("| unavailable | \(unavailablePhaseCalls) |")
        }

        let metricCalls = SessionMetrics.parse(jsonl: trafficJSONL)
        lines += [
            "",
            "telemetry availability (all provider calls):",
            "| field | known calls | unavailable calls |",
            "|---|--:|--:|",
            availabilityRow("input tokens", values: metricCalls.map(\.input)),
            availabilityRow("cache read", values: metricCalls.map(\.cacheRead)),
            availabilityRow("cache write", values: metricCalls.map(\.cacheWrite)),
            availabilityRow("output tokens", values: metricCalls.map(\.output)),
            availabilityRow("cost", values: metricCalls.map(\.cost)),
        ]
        return lines.joined(separator: "\n")
    }

    private static func classifiedValue(
        _ value: Int,
        classified: Int,
        heard: Int?,
        attemptsAvailable: Bool
    ) -> String {
        guard attemptsAvailable else { return "—" }
        guard let heard else { return "\(value) known (total heard unavailable)" }
        let unavailable = max(0, heard - classified)
        return unavailable == 0 ? String(value) : "\(value) known (\(unavailable) unavailable)"
    }

    private static func availabilityRow<T>(_ name: String, values: [T?]) -> String {
        let known = values.compactMap { $0 }.count
        return "| \(name) | \(known) | \(values.count - known) |"
    }

    private static func terminalValue(
        _ value: Int,
        unfinished: Int,
        attemptsAvailable: Bool
    ) -> String {
        guard attemptsAvailable else { return "—" }
        return unfinished == 0 ? String(value) : "\(value) known (\(unfinished) unfinished)"
    }

    private static func trafficEntries(_ jsonl: String) -> [[String: Any]] {
        jsonEntries(jsonl).filter { $0["request"] != nil }
    }

    private static func jsonEntries(_ jsonl: String) -> [[String: Any]] {
        jsonl.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
}
