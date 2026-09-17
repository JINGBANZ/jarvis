import Foundation
import JarvisBrainProviders
import JarvisCore
import Testing

/// Shaped like GitHub's release tarball: a single `jarvis-<version>/` root.
func releaseArchive(_ version: String, in fixture: URL) async throws -> URL {
    let source = fixture.appendingPathComponent("jarvis-\(version)")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("// fixture \(version)".utf8).write(to: source.appendingPathComponent("Package.swift"))
    let archive = fixture.appendingPathComponent("fixture-\(version).tar.gz")
    let output = try await AgentCLIProcessRunner.run(AgentCLIRun(
        executable: URL(fileURLWithPath: "/usr/bin/tar"),
        arguments: ["-czf", archive.path, "-C", fixture.path, source.lastPathComponent],
        stdin: nil, workingDirectory: fixture, timeout: 5))
    #expect(output.exitCode == 0)
    return archive
}

func tmp() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jarvis-test-\(ProcessInfo.processInfo.globallyUniqueString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return d
}

extension FileSessionAudit {
    static func readyForTesting(directory: URL) async -> FileSessionAudit {
        let audit = FileSessionAudit(directory: directory)
        let marker = directory.appendingPathComponent(FileSessionAudit.healthFilename)
        while !FileManager.default.fileExists(atPath: marker.path) {
            await Task.yield()
        }
        return audit
    }

    func closeForTesting() async -> SessionAuditCloseResult {
        await close()
    }
}
