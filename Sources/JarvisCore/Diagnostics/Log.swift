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
        lock.lock(); directory = dir; lock.unlock()
        // Fresh, owner-only file for the session.
        let url = dir.appendingPathComponent("jarvis-debug.log")
        FileManager.default.createFile(atPath: url.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o600])
    }

    /// The debug-log file, or nil when file logging is disabled.
    static var debugLogURL: URL? {
        lock.lock(); let dir = directory; lock.unlock()
        if let dir { return dir.appendingPathComponent("jarvis-debug.log") }
        // Headless/test override.
        if let p = ProcessInfo.processInfo.environment["JARVIS_LOG"] { return URL(fileURLWithPath: p) }
        return nil
    }
}

/// Agent-facing diagnostic logger: always writes to the unified log (Console) and additionally
/// appends to the session debug file when file logging is enabled. It deliberately never writes to
/// `ActivityLog`, whose entries are a separate, human-facing coaching record.
public func jlog(_ message: String) {
    NSLog("%@", message)

    guard let url = JarvisLog.debugLogURL else { return }
    let line = "\(logTimestamp()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
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

private func logTimestamp() -> String {
    let f = DateFormatter()
    // Fixed-format: pin locale + calendar so output is stable across locales/calendars (QA1480).
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}
