import Testing
import Foundation
@testable import JarvisCore

@Suite struct AgentCLIDetectorTests {
    private let home = URL(fileURLWithPath: "/Users/test")

    /// A probe over a fake filesystem: a set of executable paths, a set of existing files, and a
    /// map of readable file contents.
    private func probe(executables: Set<String> = [], files: Set<String> = [],
                       contents: [String: String] = [:]) -> AgentCLIDetector.Probe {
        .init(isExecutableFile: { executables.contains($0) },
              fileExists: { files.contains($0) },
              readFile: { contents[$0] })
    }

    @Test func findsClaudeOnPATH() {
        let d = AgentCLIDetector(home: home, pathVariable: "/usr/bin:/fake/bin",
                                 probe: probe(executables: ["/fake/bin/claude"]))
        let cli = d.detect(.claudeCode)
        #expect(cli?.executableURL.path == "/fake/bin/claude")
        #expect(cli?.authenticated == false)
    }

    @Test func fallsBackToKnownInstallDirsWhenPATHIsMinimal() {
        // The app is launched via `open` with launchd's bare PATH — the CLI must still be found in
        // its self-managed install location.
        let d = AgentCLIDetector(home: home, pathVariable: "/usr/bin:/bin",
                                 probe: probe(executables: ["/Users/test/.claude/local/claude"]))
        #expect(d.detect(.claudeCode)?.executableURL.path == "/Users/test/.claude/local/claude")
    }

    @Test func pathTakesPrecedenceOverFallbackDirs() {
        let d = AgentCLIDetector(home: home, pathVariable: "/fake/bin",
                                 probe: probe(executables: ["/fake/bin/codex", "/usr/local/bin/codex"]))
        #expect(d.detect(.codexCLI)?.executableURL.path == "/fake/bin/codex")
    }

    @Test func claudeAuthDetectedViaCredentialsFile() {
        let d = AgentCLIDetector(home: home, pathVariable: "/fake/bin",
                                 probe: probe(executables: ["/fake/bin/claude"],
                                              files: ["/Users/test/.claude/.credentials.json"]))
        #expect(d.detect(.claudeCode)?.authenticated == true)
    }

    @Test func claudeAuthDetectedViaOAuthAccountMarker() {
        // macOS default stores credentials in the Keychain (unprobeable without a prompt); the
        // oauthAccount record in ~/.claude.json is the visible sign-in marker there.
        let d = AgentCLIDetector(home: home, pathVariable: "/fake/bin",
                                 probe: probe(executables: ["/fake/bin/claude"],
                                              contents: ["/Users/test/.claude.json":
                                                            #"{"oauthAccount":{"emailAddress":"x@y.z"}}"#]))
        #expect(d.detect(.claudeCode)?.authenticated == true)
    }

    @Test func codexAuthDetectedViaAuthJSON() {
        let d = AgentCLIDetector(home: home, pathVariable: "/fake/bin",
                                 probe: probe(executables: ["/fake/bin/codex"],
                                              files: ["/Users/test/.codex/auth.json"]))
        #expect(d.detect(.codexCLI)?.authenticated == true)
    }

    @Test func missingBinaryDetectsNothing() {
        let d = AgentCLIDetector(home: home, pathVariable: "/fake/bin", probe: probe())
        #expect(d.detect(.claudeCode) == nil)
        #expect(d.detect(.codexCLI) == nil)
    }

    @Test func openAIProviderHasNothingToDetect() {
        let d = AgentCLIDetector(home: home, pathVariable: "/fake/bin",
                                 probe: probe(executables: ["/fake/bin/claude", "/fake/bin/codex"]))
        #expect(d.detect(.openAI) == nil)
        #expect(d.detectAll().map(\.provider) == [.claudeCode, .codexCLI])
    }
}
