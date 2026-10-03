import Foundation
import JarvisCore
import JarvisEvaluation
import Testing

extension LiveE2ETests {
    @Test func scenarioE() async throws {
        guard let launcher = await LiveE2ELauncher.begin(scenario: "E") else { return }
        let launch = try await launcher.launch()
        var results = LiveE2EResults(scenario: "E")
        guard let evidence = Self.requireEvidence(launch, &results) else {
            try launcher.finish(results)
            return
        }
        let enabledSteps = launch.stepIndices {
            if case .autoHints(true) = $0 { return true }
            return false
        }
        results.check("C31", enabledSteps.count == 2, "enable and re-enable steps ran without speech or shortcuts")
        for step in enabledSteps {
            let chain = launch.attemptChain(forStep: step)
            let rows = evidence.rows(inChain: chain)
            results.check("C31", [
                (chain.last?.isCommitted == true, "auto hint committed a response"),
                (rows.contains { $0.kind == "tip" }, "auto hint delivered a tip"),
            ])
        }
        Self.checkNoScreenshotBytes(launch, &results)
        Self.checkCleanEnd(launch, evidence, endedByUser: true, &results)
        try launcher.finish(results)
    }
}
