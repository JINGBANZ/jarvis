import Foundation
import Testing
@testable import JarvisCore

@Suite("Live cache regression threshold")
struct LiveE2ECacheCheckTests {
    private typealias Sample = LiveE2ECacheCheck.Sample

    private func samples(
        mutation: (Int, Int, Int) -> (total: Int?, read: Int?) = { _, total, read in (total, read) },
        rewriteAt: Int? = nil, revisionAt: Int? = nil
    ) -> [Sample] {
        (0..<8).map { index in
            let total = index == 0 ? 1_800 : 10_000 + index * 128
            let usage = mutation(index, total, index == 0 ? 0 : total - 128)
            return Sample(
                attemptID: index + 1, totalInput: usage.total, cacheRead: usage.read,
                instructionsFingerprint: "instructions", toolsFingerprint: "tools",
                settingsFingerprint: "settings", contextRevision: revisionAt == index ? 2 : 1,
                inputFingerprints: (0...index).map { rewriteAt == index && $0 == 0 ? "changed" : "item\($0)" })
        }
    }

    @Test("six history hits with a stable prefix pass", arguments: [BrainProvider.codexSubscription, .openAI])
    func stableHistoryPasses(provider: BrainProvider) {
        let result = LiveE2ECacheCheck.evaluate(samples(), provider: provider)
        #expect(result.passed)
        #expect(result.historyHits == 6)
        #expect((result.weightedReadRate ?? 0) >= 0.8)
    }

    @Test("subscription checkpoint rounding is tolerated only on its route")
    func subscriptionCheckpoints() {
        let allowance = LiveE2ECacheCheck.prefixTokenAllowance(for: .codexSubscription)
        #expect(allowance == 1_151)
        #expect(LiveE2ECacheCheck.prefixTokenAllowance(for: .openAI) == 256)
        let boundary = samples { _, total, _ in (total, total - 128 - allowance) }
        #expect(LiveE2ECacheCheck.evaluate(boundary, provider: .codexSubscription).passed)
        #expect(!LiveE2ECacheCheck.evaluate(boundary, provider: .openAI).passed)
        let missed = samples { _, total, _ in (total, total - 128 - allowance - 1) }
        #expect(!LiveE2ECacheCheck.evaluate(missed, provider: .codexSubscription).passed)
    }

    @Test("subscription allowance retains usage, prefix and aggregate guards")
    func subscriptionStillRejectsRegressions() {
        for values in [
            samples { _, _, _ in (2_100, 1_800) },
            samples { index, total, read in (total, index == 2 || index == 3 ? 0 : read) },
            samples { index, total, read in (total, index == 2 ? nil : read) },
            samples(rewriteAt: 4),
            samples(revisionAt: 4),
        ] {
            #expect(!LiveE2ECacheCheck.evaluate(values, provider: .codexSubscription).passed)
        }
    }

    @Test("one cold request is tolerated; two regressions fail")
    func toleratesOnlyOneColdRequest() {
        let one = samples { index, total, read in (total, index == 2 ? 0 : read) }
        let two = samples { index, total, read in (total, index == 2 || index == 3 ? 0 : read) }
        #expect(LiveE2ECacheCheck.evaluate(one).passed)
        #expect(!LiveE2ECacheCheck.evaluate(two).passed)
    }

    @Test("missing counters cannot become a measured zero or a passing rate")
    func missingUsageFails() {
        let missingRead = samples { index, total, read in (total, index == 2 ? nil : read) }
        let missingTotal = samples { index, total, read in (index == 2 ? nil : total, read) }
        for values in [missingRead, missingTotal] {
            let result = LiveE2ECacheCheck.evaluate(values)
            #expect(!result.passed)
            #expect(result.weightedReadRate == nil)
        }
    }

    @Test("static-prefix caching alone cannot pass the history threshold")
    func staticOnlyFails() {
        let values = samples { _, _, _ in (2_100, 1_800) }
        let result = LiveE2ECacheCheck.evaluate(values)
        #expect((result.weightedReadRate ?? 0) >= 0.8)
        #expect(!result.passed)
    }

    @Test("rewritten input or a declared reset leaves the steady window")
    func rewriteFails() {
        #expect(!LiveE2ECacheCheck.evaluate(samples(rewriteAt: 4)).passed)
        #expect(!LiveE2ECacheCheck.evaluate(samples(revisionAt: 4)).passed)
    }

    @Test("invalid or incomplete evidence cannot pass")
    func invalidEvidenceFails() {
        #expect(!LiveE2ECacheCheck.evaluate(Array(samples().dropLast())).passed)
        #expect(!LiveE2ECacheCheck.evaluate(samples { _, _, _ in (.max, .max) }).passed)
        #expect(!LiveE2ECacheCheck.evaluate(samples { _, total, _ in (total, total + 1) }).passed)
    }
}
