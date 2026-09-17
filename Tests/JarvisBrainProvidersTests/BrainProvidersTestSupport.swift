import Foundation
import JarvisCore
import Testing

func tmp() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jarvis-test-\(ProcessInfo.processInfo.globallyUniqueString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return d
}

extension FileSessionAudit {
    /// Bounded, so a worker that never opens the session fails here instead of at CI's job timeout.
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

    func closeForTesting() async -> SessionAuditCloseResult {
        await close()
    }
}
