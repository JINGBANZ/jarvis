import Foundation
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
            (Self.precedes(search?.index, read?.index), "search found a document before it was read"),
            (Self.precedes(read?.index, tip?.index), "document read preceded the reply"),
        ])
        let original = try String(contentsOf: LiveE2ELauncher.fixturesDirectory
            .appendingPathComponent("prep-notes.md"), encoding: .utf8)
        let session = try #require(launch.sessionDirectory)
        let traffic = try String(contentsOf: session.appendingPathComponent("brain-traffic.jsonl"), encoding: .utf8)
        let completeTextReachedBrain = traffic.split(separator: "\n").contains { line in
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let request = record["request"] as? [String: Any],
                  let input = request["input"] as? [[String: Any]] else { return false }
            return input.contains {
                $0["type"] as? String == "function_call_output"
                    && ($0["output"] as? String)?.contains(original) == true
            }
        }
        results.check("C34", completeTextReachedBrain, "the complete extracted fixture reached the brain")
        Self.checkCleanEnd(launch, evidence, endedByUser: true, &results)
        try launcher.finish(results)
    }
}
