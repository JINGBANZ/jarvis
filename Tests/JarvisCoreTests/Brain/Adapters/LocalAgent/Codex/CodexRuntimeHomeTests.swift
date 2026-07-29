import Foundation
import Testing
@testable import JarvisCore

@Suite struct CodexRuntimeHomeTests {
    @Test func keepsCredentialLinkOutsideTheRetainedSessionTree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRuntimeHomeTests-\(UUID().uuidString)")
        let session = root.appendingPathComponent("session", isDirectory: true)
        let runtimeBase = root.appendingPathComponent("application-support", isDirectory: true)
        let authFile = root.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(
            at: session,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data("credential".utf8).write(to: authFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let home = try CodexRuntimeHome.create(
            in: runtimeBase,
            authFile: authFile)

        #expect(home.deletingLastPathComponent().standardizedFileURL
            == runtimeBase.standardizedFileURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.path).isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: home.appendingPathComponent("auth.json").path) == authFile.path)
        let baseMode = try #require(
            FileManager.default.attributesOfItem(atPath: runtimeBase.path)[.posixPermissions]
                as? NSNumber)
        let homeMode = try #require(
            FileManager.default.attributesOfItem(atPath: home.path)[.posixPermissions]
                as? NSNumber)
        #expect(baseMode.intValue == 0o700)
        #expect(homeMode.intValue == 0o700)
    }
}
