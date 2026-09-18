import Foundation
import JarvisCore
import JarvisEvaluation
import Testing

extension LiveE2ETests {
    @Test func scenarioD() async throws {
        guard let launcher = await LiveE2ELauncher.begin(scenario: "D") else { return }
        let launch = try await launcher.launch()
        var results = LiveE2EResults(scenario: "D")
        guard let evidence = Self.requireEvidence(launch, &results) else {
            try launcher.finish(results)
            return
        }
        let presses = launch.stepIndices(Self.isPress)
        let says = launch.stepIndices(Self.isSay)
        guard presses.count == 5, says.count == 5 else {
            results.check("D", false, "five hint presses and five spoken steps ran "
                + "(saw \(presses.count), \(says.count))")
            try launcher.finish(results)
            return
        }
        let chains = presses.map { launch.attemptChain(forStep: $0) }
        for (index, chain) in chains.enumerated() {
            let label = "D hint \(index + 1)"
            Self.noteStalls([(label, chain)], evidence, &results)
            let tip = evidence.rows(inChain: chain).last { $0.kind == "tip" }
            results.check("C28", [
                (chain.last?.isCommitted == true, "\(label) committed a reply"),
                (tip?.response?.lines.contains {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } == true, "\(label) delivered hint text"),
                (tip.map { !Self.carriesProtocolText($0.message) } ?? false,
                 "\(label) delivered no protocol text"),
            ])
            results.time("\(label) press-to-tip", seconds: Self.pressToTip(evidence, chain))
        }

        // Speech can trigger a load before the subsequent shortcut, so use committed session rows.
        let loadedRows = evidence.attempts.filter(\.isCommitted).flatMap { evidence.rows(in: $0) }
        let reviewTip = evidence.rows(inChain: chains[1]).last { $0.kind == "tip" }
        for skill in ["coding-with-ai", "coding"] {
            let load = loadedRows.first { $0.loadedCapability?.name == skill }
            results.check("C28", Self.precedes(load?.index, reviewTip?.index),
                          "\(skill) loaded before the permitted AI review tip")
        }
        let correctiveChains = [launch.attemptChain(forStep: says[2]), chains[2]]
        let hasCorrectiveDetail = correctiveChains.contains { chain in
            guard let detail = Self.deliveredDetail(evidence, chain),
                  !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            // The candidate is delegating the edit. A direct implementation block is the observed
            // regression, not a substitute for the next prompt. The rubric checks its meaning.
            guard let rendered = ReplyDetail(markdown: detail), rendered.hasContent else { return false }
            return rendered.code == nil
        }
        results.check("C29", hasCorrectiveDetail,
                      "the blocked delegation step delivered supporting detail without an explicit prompt request")
        let comprehensionChains = [launch.attemptChain(forStep: says[3]), chains[3]]
        let hasComprehensionDetail = comprehensionChains.contains { chain in
            guard let detail = Self.deliveredDetail(evidence, chain),
                  let rendered = ReplyDetail(markdown: detail) else { return false }
            return rendered.hasContent
        }
        results.check("C30", hasComprehensionDetail,
                      "review of a valid AI proposal delivered supporting detail without a confusion signal")
        results.note("C29", "Structural checks only. Semantic review NOT EVALUATED: apply "
            + "Tests/JarvisLiveTests/Scenarios/D-review.md to the recorded replies. "
            + "AI proposal and test results are spoken reports; the JPEG is OCR-only and proves no Chrome AX coverage.")
        Self.checkNoScreenshotBytes(launch, &results)
        Self.checkCleanEnd(launch, evidence, endedByUser: true, &results)
        try launcher.finish(results)
    }
}
