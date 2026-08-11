import Foundation

/// Per-session file logging config. By default `jlog` writes ONLY to the unified log (Console.app);
/// no flat file is created. On each Start the app calls `JarvisLog.enableFileLogging(directory:)`,
/// after which `jlog` also appends to `<directory>/jarvis-debug.log` (created `0600`, truncated
/// fresh for the session). The file is always owner-only and never lands in a world-readable path —
/// see wiki/sandbox.md ("per-session log directory").
public enum JarvisLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var directory: URL?   // guarded by `lock`

    public static func enableFileLogging(directory dir: URL) {
        lock.lock()
        defer { lock.unlock() }
        directory = dir
        // Fresh, owner-only file for the session.
        let url = dir.appendingPathComponent("jarvis-debug.log")
        FileManager.default.createFile(atPath: url.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o600])
    }

    /// Serialize the open-seek-write sequence. Separate file handles can otherwise seek to the same
    /// end offset and overwrite a peer diagnostic emitted at the same time.
    fileprivate static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        let url: URL?
        if let directory {
            url = directory.appendingPathComponent("jarvis-debug.log")
        } else if let path = ProcessInfo.processInfo.environment["JARVIS_LOG"] {
            url = URL(fileURLWithPath: path)
        } else {
            url = nil
        }
        guard let url else { return }

        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            // First write of the session (or after enable truncated it): create owner-only.
            FileManager.default.createFile(atPath: url.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
    }
}

/// Agent-facing diagnostic logger: always writes to the unified log (Console) and additionally
/// appends to the session debug file when file logging is enabled. It deliberately never writes to
/// `ActivityLog`, whose entries are a separate, human-facing coaching record.
public func jlog(_ message: String) {
    NSLog("%@", message)
    JarvisLog.append("\(logTimestamp()) \(message)\n")
}

private func logTimestamp() -> String {
    let f = DateFormatter()
    // Fixed-format: pin locale + calendar so output is stable across locales/calendars (QA1480).
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}
