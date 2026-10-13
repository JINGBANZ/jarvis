import Foundation
import JarvisBrainProviders
import Testing

extension LiveE2ETests {
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
        Self.recordTokens(evidence, &results)
        Self.recordTokens(evidence, &results, tag: "summarizer")
        Self.checkCleanEnd(launch, evidence, endedByUser: true, &results)
        try launcher.finish(results)
    }
}
