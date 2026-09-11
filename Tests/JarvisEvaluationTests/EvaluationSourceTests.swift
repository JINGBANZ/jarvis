import Foundation
import Testing
@testable import JarvisEvaluation

@Suite struct EvaluationSourceTests {
    @Test func buildChoosesPathAndSessionChoosesVersion() {
        let bundle = URL(fileURLWithPath: "/checkout/Jarvis Dev.app")
        #expect(EvaluationSource.resolve(isDevelopmentBuild: true, bundleURL: bundle,
                                         recordedVersion: nil) == .localCheckout(
                                            URL(fileURLWithPath: "/checkout", isDirectory: true)))
        #expect(EvaluationSource.resolve(isDevelopmentBuild: true, bundleURL: bundle,
                                         recordedVersion: "0.2.1") == .localCheckout(
                                            URL(fileURLWithPath: "/checkout", isDirectory: true)))
        #expect(EvaluationSource.resolve(isDevelopmentBuild: false, bundleURL: bundle,
                                         recordedVersion: "0.2.1") == .release(version: "0.2.1"))
        #expect(EvaluationSource.resolve(isDevelopmentBuild: false, bundleURL: bundle,
                                         recordedVersion: nil) == nil)
    }

    @Test(arguments: ["../0.2.1", "0.2.1/../../tmp", "0.2.1;echo hi", "$(id)",
                      "v0.2.1", "0.2.1\n", "0.2.1-beta", "", "１.２.３"])
    func rejectsUntrustedVersions(_ version: String) {
        #expect(!EvaluationSource.isValidVersion(version))
    }

    @Test func sessionStampIsReleaseOnlyAndOwnerOnly() throws {
        let directory = tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        try SessionBuild.write(in: directory, isDevelopmentBuild: true, version: "0.2.2")
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(SessionBuild.filename).path))
        try SessionBuild.write(in: directory, isDevelopmentBuild: false, version: "0.2.1")
        let stamp = try #require(SessionBuild.read(in: directory))
        #expect(stamp.version == "0.2.1")
        #expect(stamp.format == 1)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(SessionBuild.filename).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func missingMalformedAndUnsupportedStampsDoNotInventVersion() throws {
        let directory = tmp()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SessionBuild.read(in: directory) == nil)
        let stamp = directory.appendingPathComponent(SessionBuild.filename)
        for contents in ["not json", #"{"version":"0.2.1","format":2}"#] {
            try Data(contents.utf8).write(to: stamp)
            #expect(SessionBuild.read(in: directory) == nil)
        }
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
