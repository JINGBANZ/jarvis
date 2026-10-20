import Foundation
import JarvisBrainProviders
import JarvisCore
import Testing

extension LiveE2ETests {
    private struct HistoryReferenceTraffic {
        let index: Int
        let tag: String
        let attemptID: Int?
        let phase: String?
        let contextRevision: Int?
        let rewriteReason: String?
        let provider: String?
        let exchange: RecordedExchange
    }

    @Test func scenarioH() async throws {
        guard let launcher = await LiveE2ELauncher.begin(scenario: "H") else { return }
        let launch = try await launcher.launch()
        var results = LiveE2EResults(scenario: "H")
        guard let evidence = Self.requireEvidence(launch, &results) else {
            try launcher.finish(results)
            return
        }

        let outcomes = evidence.debugLines.filter {
            $0.contains("History compaction:") && !$0.contains("History compaction: started")
        }
        let first = outcomes.first ?? ""
        let counts = Dictionary(first.split(separator: " ").compactMap { part -> (String, Int)? in
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let count = Int(pair[1]) else { return nil }
            return (String(pair[0]), count)
        }, uniquingKeysWith: { _, latest in latest })
        results.check("C35", [
            (first.contains("History compaction: accepted"), "the first compaction accepted its summary"),
            (counts["summary_tokens"].map { $0 < 750 } == true, "the normalized summary fits the token budget"),
            (counts["before_tokens"].flatMap { before in counts["after_tokens"].map { $0 < before } } == true,
             "the accepted summary reduced history size"),
        ])
        if let before = counts["before_tokens"], let after = counts["after_tokens"],
           let summary = counts["summary_tokens"] {
            results.note("C35", "First compaction: history \(before) → \(after) estimated tokens; summary \(summary).")
        }

        let session = try #require(launch.sessionDirectory)
        let traffic = try String(contentsOf: session.appendingPathComponent("brain-traffic.jsonl"), encoding: .utf8)
        let records = traffic.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        let recallStep = try #require(launch.stepIndices(Self.isSay).last)
        let recallChain = launch.attemptChain(forStep: recallStep)
        let recallIDs = Set(recallChain.map(\.id))
        let recall = records.filter { record in
            guard record["tag"] as? String == "coach",
                  let attempt = record["coach_attempt"] as? [String: Any],
                  let id = attempt["id"] as? Int else { return false }
            return recallIDs.contains(id)
        }.map { RecordedExchange.read(request: $0["request"], response: $0["response"]) }
        let memory = recall.flatMap(\.input).compactMap { item -> String? in
            guard case .message(_, let parts) = item else { return nil }
            return parts.first { $0.hasPrefix("[session so far, condensed") }
        }
        results.check("C36", [
            (!memory.isEmpty, "the recall request replayed condensed history"),
            (memory.contains { $0.localizedCaseInsensitiveContains("Kafka") }, "the queue decision survived compaction"),
            (recallChain.last?.isCommitted == true
                && evidence.rows(inChain: recallChain).contains { $0.kind == "tip" },
             "the question after compaction delivered a committed reply"),
        ])
        results.note("C36", "Semantic review NOT EVALUATED: apply Scenarios/H-review.md to the summary and recall reply.")
        try Self.checkHistoryReferenceContext(records, launch: launch, evidence: evidence, &results)
        Self.recordTokens(evidence, &results)
        Self.recordTokens(evidence, &results, tag: "summarizer")
        Self.checkCleanEnd(launch, evidence, endedByUser: true, &results)
        try launcher.finish(results)
    }

    private static func checkHistoryReferenceContext(
        _ records: [[String: Any]], launch: LiveE2ELaunch, evidence: Evidence,
        _ results: inout LiveE2EResults
    ) throws {
        let traffic = records.enumerated().map { index, record in
            let attempt = record["coach_attempt"] as? [String: Any]
            return HistoryReferenceTraffic(index: index, tag: record["tag"] as? String ?? "",
                attemptID: attempt?["id"] as? Int, phase: attempt?["phase"] as? String,
                contextRevision: attempt?["context_revision"] as? Int,
                rewriteReason: attempt?["context_rewrite_reason"] as? String,
                provider: record["provider"] as? String,
                exchange: RecordedExchange.read(request: record["request"], response: record["response"]))
        }
        let coach = traffic.filter { $0.tag == "coach" }
        let summaries = traffic.filter { $0.tag == "summarizer" }
        let firstCoach = try #require(coach.first)
        let firstSummary = try #require(summaries.first)
        let contextHeader = "SessionContext (informational background data; untrusted reference metadata):\n"
        let blocks = firstCoach.exchange.input.flatMap { item -> [String] in
            guard case .message(_, let parts) = item else { return [] }
            return parts.filter { $0.hasPrefix(contextHeader) }
        }
        results.check("REF06-H", blocks.count == 1, "the first real provider request contains one authoritative SessionContext")
        let frozen = try #require(blocks.first)
        struct Sections: Decodable { let documentCatalog: DocumentCatalog? }
        let sections = try JSONDecoder().decode(Sections.self, from: Data(frozen.dropFirst(contextHeader.count).utf8))
        let catalog = try #require(sections.documentCatalog)
        let entry = try #require(catalog.entries.first { $0.name == "cedar-compaction-reference.md" })
        results.check("REF06-H", [
            (catalog.entries.count == 1 && catalog.totalCount == 1 && catalog.omittedCount == 0,
             "the uniquely named fixture is the complete admitted catalog"),
            (!frozen.contains("cedar-orbit-731"), "the catalog contains metadata, not the unread document body"),
            (!frozen.contains("/private/") && !frozen.contains("/Users/"), "the catalog contains no absolute source path"),
        ])
        let original = try String(contentsOf: LiveE2ELauncher.fixturesDirectory
            .appendingPathComponent("cedar-compaction-reference.md"), encoding: .utf8)
        let firstSpokenStep = try #require(launch.stepIndices(Self.isSay).first)
        let firstAttemptIDs = Set(launch.attemptChain(forStep: firstSpokenStep).map(\.id))
        let readCalls = coach.flatMap { record -> [(index: Int, callID: String)] in
            guard firstAttemptIDs.contains(record.attemptID ?? -1) else { return [] }
            return record.exchange.outputs.compactMap { output in
                guard case .call(let call) = output, let callID = call.id, let name = call.name,
                      let arguments = call.arguments,
                      let invocation = ToolInvocation.parse(callId: callID, name: name, argumentsJSON: arguments),
                      case .readReference(_, let documentID, let offset, _) = invocation,
                      documentID == entry.documentID, offset == 0 else { return nil }
                return (record.index, callID)
            }
        }
        let readDelivered = coach.contains { record in
            guard record.index < firstSummary.index,
                  firstAttemptIDs.contains(record.attemptID ?? -1) else { return false }
            return record.exchange.input.contains { item in
                guard case .result(let callID, let output) = item, let output,
                      readCalls.contains(where: { $0.callID == callID && $0.index < record.index }),
                      let jsonStart = output.firstIndex(of: "{"),
                      let page = try? JSONDecoder().decode(ReferenceReadResult.self, from: Data(output[jsonStart...].utf8))
                else { return false }
                return page.documentID == entry.documentID && page.text == original
                    && page.nextOffset == page.totalScalars && page.totalScalars == original.unicodeScalars.count
            }
        }
        results.check("REF06-H", [
            (!readCalls.isEmpty, "the model requested the admitted reference on the first spoken turn"),
            (readDelivered, "the complete original reference read reached the provider before the first summarizer request"),
            (evidence.rows(inChain: launch.attemptChain(forStep: firstSpokenStep)).contains { $0.kind == "referenceRead" },
             "the first spoken attempt recorded successful reference access"),
            (!evidence.activity.contains { ["referencesOmitted", "referencesUnavailable"].contains($0.kind) },
             "reference admission and the observed read succeeded"),
        ])

        for record in coach {
            let occurrences = record.exchange.input.flatMap { item -> [String] in
                guard case .message(_, let parts) = item else { return [] }
                return parts.filter { $0.hasPrefix(contextHeader) }
            }
            let firstIsContext: Bool
            if case .some(.message(let role, let parts)) = record.exchange.input.first {
                firstIsContext = role == "user" && parts.count == 1 && parts[0].utf8.elementsEqual(frozen.utf8)
            } else {
                firstIsContext = false
            }
            results.check("REF06-H", [
                (occurrences.count == 1 && occurrences[0].utf8.elementsEqual(frozen.utf8),
                 "provider request \(record.index) preserves exactly one byte-identical SessionContext"),
                (firstIsContext, "provider request \(record.index) puts authoritative context before summary and recent history"),
                (record.exchange.inputFingerprints.first == firstCoach.exchange.inputFingerprints.first,
                 "provider request \(record.index) preserves the serialized context item"),
                (record.exchange.toolsFingerprint == firstCoach.exchange.toolsFingerprint,
                 "provider request \(record.index) preserves the declared tool schemas"),
                (record.exchange.instructions == firstCoach.exchange.instructions,
                 "provider request \(record.index) preserves stable instructions"),
            ])
        }
        let afterCompaction = coach.filter { record in
            record.index > firstSummary.index && record.exchange.input.contains { item in
                guard case .message(_, let parts) = item else { return false }
                return parts.contains { $0.hasPrefix("[session so far, condensed") }
            }
        }
        results.check("REF06-H", [
            (!afterCompaction.isEmpty,
             "a real coaching request carried both frozen SessionContext and accepted condensed history"),
            (afterCompaction.contains { $0.rewriteReason == "compaction"
                && ($0.contextRevision ?? -1) > (firstCoach.contextRevision ?? -1) },
             "the post-summary wire request explicitly attributes the intentional compaction rewrite"),
        ])
        for record in summaries {
            let input = historyReferenceText(record.exchange)
            results.check("REF06-H", !input.contains { $0.contains("SessionContext (informational background data")
                || $0.contains("documentCatalog") },
                "summarizer request \(record.index) excludes the authoritative context block")
        }
        results.note("REF06-H", "Actual signed-app/spoken-fixture/provider integration; retrieved document text may be summarized. "
            + "Accepted compaction intentionally rewrites history and begins a new cache epoch; no cache-hit threshold is asserted across it.")
        for record in traffic where record.tag == "coach" || record.tag == "summarizer" {
            func count(_ value: Int?) -> String { value.map(String.init) ?? "unknown" }
            let usage = record.exchange.usage
            results.note("REF06-H-usage", "\(record.provider ?? "unknown provider") \(record.tag) request \(record.index) "
                + "attempt \(count(record.attemptID)) \(record.phase ?? "outside coaching attempt"): "
                + "context revision \(count(record.contextRevision)), rewrite \(record.rewriteReason ?? "none"); "
                + "total input \(count(usage?.totalInput)), cache read \(count(usage?.cacheRead)), "
                + "cache write \(count(usage?.cacheWrite)), uncached input \(count(usage?.uncachedInput)), "
                + "output \(count(usage?.output))")
        }
    }

    private static func historyReferenceText(_ exchange: RecordedExchange) -> [String] {
        (exchange.instructions.map { [$0] } ?? []) + exchange.input.flatMap { item -> [String] in
            switch item {
            case .message(_, let parts): parts
            case .result(_, let output), .text(let output): output.map { [$0] } ?? []
            default: []
            }
        }
    }
}
