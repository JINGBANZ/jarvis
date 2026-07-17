import Testing
import Foundation
@testable import JarvisCore

/// Detection runs against a real, throwaway home-directory fixture (no production probe seam):
/// executables are actual 0755 files, auth markers actual files — only `home` and `pathVariable`
/// are injected, the same way `BrainPreferences` takes a `UserDefaults(suiteName:)`.
@Suite struct AgentCLIDetectorTests {
    private let fm = FileManager.default

    /// A fresh fake home directory per test.
    private func makeHome() throws -> URL {
        let url = fm.temporaryDirectory
            .appendingPathComponent("AgentCLIDetectorTests-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Create a real executable file at `dir/name`.
    private func installBinary(_ name: String, in dir: URL) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(fm.createFile(atPath: dir.appendingPathComponent(name).path,
                              contents: Data("#!/bin/sh\n".utf8),
                              attributes: [.posixPermissions: 0o755]))
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// True when a machine-wide claude/codex lives in the absolute fallback dirs the detector
    /// consults regardless of the fixture home. The negative-detection tests adapt by returning
    /// early — on such a machine, detecting that install is correct behavior, not a failure.
    private var systemWideCLIInstalled: Bool {
        ["/opt/homebrew/bin", "/usr/local/bin"].contains {
            fm.isExecutableFile(atPath: "\($0)/claude") || fm.isExecutableFile(atPath: "\($0)/codex")
        }
    }

    @Test func findsClaudeOnPATH() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("claude", in: bin)
        let d = AgentCLIDetector(home: home, pathVariable: "/nonexistent:\(bin.path)")
        let cli = d.detect(.claudeCode)
        #expect(cli?.executableURL.path == bin.appendingPathComponent("claude").path)
        #expect(cli?.authenticated == false)
    }

    @Test func fallsBackToKnownInstallDirsWhenPATHIsMinimal() throws {
        // The app is launched via `open` with launchd's bare PATH — the CLI must still be found in
        // its self-managed install location under the home directory.
        let home = try makeHome()
        try installBinary("claude", in: home.appendingPathComponent(".claude/local"))
        let d = AgentCLIDetector(home: home, pathVariable: "/nonexistent")
        #expect(d.detect(.claudeCode)?.executableURL.path
                == home.appendingPathComponent(".claude/local/claude").path)
    }

    @Test func pathTakesPrecedenceOverFallbackDirs() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("codex", in: bin)
        try installBinary("codex", in: home.appendingPathComponent(".cargo/bin"))
        let d = AgentCLIDetector(home: home, pathVariable: bin.path)
        #expect(d.detect(.codexCLI)?.executableURL.path == bin.appendingPathComponent("codex").path)
    }

    @Test func nonExecutableFileIsNotDetected() throws {
        guard !systemWideCLIInstalled else { return }
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try write("not a binary", to: bin.appendingPathComponent("claude"))   // 0644, no exec bit
        let d = AgentCLIDetector(home: home, pathVariable: bin.path)
        #expect(d.detect(.claudeCode) == nil)
    }

    @Test func claudeAuthDetectedViaCredentialsFile() throws {
        let home = try makeHome()
        try installBinary("claude", in: home.appendingPathComponent(".local/bin"))
        try write("{}", to: home.appendingPathComponent(".claude/.credentials.json"))
        let d = AgentCLIDetector(home: home, pathVariable: nil)
        #expect(d.detect(.claudeCode)?.authenticated == true)
    }

    @Test func claudeAuthDetectedViaOAuthAccountMarker() throws {
        // macOS default stores credentials in the Keychain (unprobeable without a prompt); the
        // oauthAccount record in ~/.claude.json is the visible sign-in marker there.
        let home = try makeHome()
        try installBinary("claude", in: home.appendingPathComponent(".local/bin"))
        try write(#"{"oauthAccount":{"emailAddress":"x@y.z"}}"#,
                  to: home.appendingPathComponent(".claude.json"))
        let d = AgentCLIDetector(home: home, pathVariable: nil)
        #expect(d.detect(.claudeCode)?.authenticated == true)
    }

    @Test func codexAuthDetectedViaAuthJSON() throws {
        let home = try makeHome()
        try installBinary("codex", in: home.appendingPathComponent(".local/bin"))
        try write("{}", to: home.appendingPathComponent(".codex/auth.json"))
        let d = AgentCLIDetector(home: home, pathVariable: nil)
        #expect(d.detect(.codexCLI)?.authenticated == true)
    }

    @Test func missingBinaryDetectsNothing() throws {
        guard !systemWideCLIInstalled else { return }
        let home = try makeHome()
        let d = AgentCLIDetector(home: home, pathVariable: "/nonexistent")
        #expect(d.detect(.claudeCode) == nil)
        #expect(d.detect(.codexCLI) == nil)
    }

    @Test func openAIProviderHasNothingToDetect() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("fakebin")
        try installBinary("claude", in: bin)
        try installBinary("codex", in: bin)
        let d = AgentCLIDetector(home: home, pathVariable: bin.path)
        #expect(d.detect(.openAI) == nil)
        #expect(d.detectAll().map(\.provider) == [.claudeCode, .codexCLI])
    }
}
