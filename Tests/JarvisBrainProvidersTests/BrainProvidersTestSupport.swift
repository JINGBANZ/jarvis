import Foundation
import JarvisCore
import Testing

/// An owner-only scratch directory for one test.
func tmp() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jarvis-test-\(ProcessInfo.processInfo.globallyUniqueString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return d
}

/// The adapter's traffic-recording tests need real on-disk artifacts in the exact shape the live
/// writer produces, so they drive `FileSessionAudit` through its public production API (the shared
/// worker); per-test directories keep sessions isolated. Core's own persistence tests keep their
/// separate isolated-worker fixture.
extension FileSessionAudit {
    /// Wait for the asynchronous open before sending the record under test, so the assertion
    /// observes the same ordered lifecycle as production. The wait is bounded: if the worker never
    /// writes the health marker (open failure, saturation), the test fails loudly with this
    /// fixture's diagnosis instead of stalling until CI's job timeout.
    static func readyForTesting(directory: URL) async -> FileSessionAudit {
        let audit = FileSessionAudit(directory: directory)
        let marker = directory.appendingPathComponent(FileSessionAudit.healthFilename)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: marker.path) {
            guard ContinuousClock.now < deadline else {
                Issue.record("""
                    the session audit at \(directory.path) never wrote \
                    \(FileSessionAudit.healthFilename); the shared audit worker failed or \
                    stalled instead of opening the session
                    """)
                return audit
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return audit
    }

    /// Persistence assertions await the real asynchronous lifecycle.
    func closeForTesting() async -> SessionAuditCloseResult {
        await close()
    }
}
