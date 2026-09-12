import Foundation
import JarvisBrainProviders
import JarvisCore
import Testing

/// A tarball shaped like GitHub's release archive: a single `jarvis-<version>/` root whose
/// `Package.swift` names its version, so a test can tell which source tree a run actually used.
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

/// An owner-only scratch directory for one test.
func tmp() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jarvis-test-\(ProcessInfo.processInfo.globallyUniqueString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return d
}

/// Evaluation tests need real on-disk session artifacts in the exact shape the live writer
/// produces, so they drive `FileSessionAudit` through its public production API (the shared
/// worker); per-test directories keep sessions isolated. Core's own persistence tests keep their
/// separate isolated-worker fixture.
extension FileSessionAudit {
    /// Wait for the asynchronous open before sending the record under test, so the assertion
    /// observes the same ordered lifecycle as production.
    static func readyForTesting(directory: URL) async -> FileSessionAudit {
        let audit = FileSessionAudit(directory: directory)
        let marker = directory.appendingPathComponent(FileSessionAudit.healthFilename)
        while !FileManager.default.fileExists(atPath: marker.path) {
            await Task.yield()
        }
        return audit
    }

    /// Persistence assertions await the real asynchronous lifecycle.
    func closeForTesting() async -> SessionAuditCloseResult {
        await close()
    }
}
