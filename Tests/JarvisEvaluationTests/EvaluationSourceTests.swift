import Foundation
import Testing
import JarvisCore
@testable import JarvisEvaluation

@Suite struct EvaluationSourceTests {
    @Test func buildChoosesPathAndSessionChoosesVersion() {
        let bundle = URL(fileURLWithPath: "/checkout/Jarvis Dev.app")
        #expect(EvaluationSource.resolve(isDevelopmentBuild: true, bundleURL: bundle,
                                         sessionID: "dev-2026-09-12_10-00-00_abcd", currentVersion: "0.2.2") == .localCheckout(
                                            URL(fileURLWithPath: "/checkout", isDirectory: true)))
        #expect(EvaluationSource.resolve(isDevelopmentBuild: true, bundleURL: bundle,
                                         sessionID: "2026-09-12_10-00-00_abcd", currentVersion: "0.2.2") == .localCheckout(
                                            URL(fileURLWithPath: "/checkout", isDirectory: true)))
        #expect(EvaluationSource.resolve(isDevelopmentBuild: false, bundleURL: bundle,
                                         sessionID: "v0.2.1-2026-09-12_10-00-00_abcd", currentVersion: "0.2.2")
                == .release(version: "0.2.1", fallbackVersion: "0.2.2"))
        #expect(EvaluationSource.resolve(isDevelopmentBuild: false, bundleURL: bundle,
                                         sessionID: "2026-09-12_10-00-00_abcd", currentVersion: "0.2.2")
                == .release(version: nil, fallbackVersion: "0.2.2"))
    }

    @Test(arguments: ["../0.2.1", "0.2.1/../../tmp", "0.2.1;echo hi", "$(id)",
                      "v0.2.1", "0.2.1\n", "0.2.1-beta", "", "１.２.３"])
    func rejectsUntrustedVersions(_ version: String) {
        #expect(!EvaluationSource.isValidVersion(version))
    }

    @Test func fallbackProvenanceNeverClaimsExactSource() {
        let recorded = EvaluationSource.release(version: "0.2.1", fallbackVersion: "0.2.2")
            .releaseProvenance(using: "0.2.2")
        #expect(recorded.contains("recorded with Jarvis 0.2.1"))
        #expect(recorded.contains("uses released source for Jarvis 0.2.2"))
        #expect(recorded.contains("may not match"))
        #expect(!recorded.contains("the exact code"))
        let unknown = EvaluationSource.release(version: nil, fallbackVersion: "0.2.2")
            .releaseProvenance(using: "0.2.2")
        #expect(unknown.contains("version is unknown"))
        #expect(unknown.contains("Jarvis 0.2.2"))
    }

    @Test func promptsExplainBothSourceProvenances() {
        let release = EvaluationSource.release(version: "0.2.1")
        let development = EvaluationSource.localCheckout(URL(fileURLWithPath: "/repo"))
        let releasePrompt = AgenticEvaluation.prompt(sessionDirPath: "/session",
                                                     workspaceProvenance: release.workspaceProvenance)
        let developmentPrompt = AgenticEvaluation.prompt(sessionDirPath: "/session",
                                                         workspaceProvenance: development.workspaceProvenance)
        #expect(releasePrompt.contains("released source for Jarvis 0.2.1, the exact code"))
        #expect(releasePrompt.contains("It carries no git history."))
        #expect(developmentPrompt.contains("live development checkout"))
        #expect(developmentPrompt.contains("including uncommitted edits"))
        #expect(releasePrompt.replacingOccurrences(of: release.workspaceProvenance, with: "")
                == developmentPrompt.replacingOccurrences(of: development.workspaceProvenance, with: ""))
    }
}
