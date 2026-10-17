import Foundation
import JarvisBrainProviders
import JarvisCore
import Testing

extension LiveE2ETests {
    @Test func scenarioP() async throws {
        guard let launcher = await LiveE2ELauncher.begin(scenario: "P") else { return }
        let launch = try await launcher.launch()
        var results = LiveE2EResults(scenario: "P")
        guard let evidence = Self.requireEvidence(launch, &results) else {
            try launcher.finish(results)
            return
        }
        let search = evidence.activity.first { $0.kind == "prepNotesSearched" }
        let read = evidence.activity.first { $0.kind == "prepNoteRead" }
        let tip = evidence.activity.first { $0.kind == "tip" }
        results.check("C34", [
            (search == nil, "the named document was read directly from the catalog without a search"),
            (Self.precedes(read?.index, tip?.index), "document read preceded the reply"),
        ])
        let original = try String(contentsOf: LiveE2ELauncher.fixturesDirectory
            .appendingPathComponent("prep-notes.md"), encoding: .utf8)
        let session = try #require(launch.sessionDirectory)
        let completeTextReachedBrain = try Self.prepTextReachedBrain(original, in: session)
        results.check("C34", completeTextReachedBrain, "the complete extracted fixture reached the brain")
        let says = launch.stepIndices(Self.isSay)
        results.check("C34", says.count == 3, "all three document and design questions ran")
        for step in says {
            let chain = launch.attemptChain(forStep: step)
            results.check("C34", chain.last?.isCommitted == true
                && evidence.rows(inChain: chain).contains { $0.kind == "tip" },
                "spoken step \(step) delivered a committed answer")
        }
        results.note("C34", "Semantic review NOT EVALUATED: apply Scenarios/P-review.md to the replies.")
        Self.checkCleanEnd(launch, evidence, endedByUser: true, &results)
        try launcher.finish(results)
    }

    private static func prepTextReachedBrain(_ text: String, in session: URL) throws -> Bool {
        let traffic = try String(contentsOf: session.appendingPathComponent("brain-traffic.jsonl"), encoding: .utf8)
        return traffic.split(separator: "\n").contains { line in
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let request = record["request"] as? [String: Any] else { return false }
            return RecordedExchange.read(request: request, response: record["response"]).input.contains {
                guard case .result(_, let output) = $0 else { return false }
                return output?.contains(text) == true
            }
        }
    }
}
