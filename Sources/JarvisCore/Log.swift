import Foundation

/// Dev-only file logging config. By default `jlog` writes ONLY to the unified log (Console.app);
/// no flat file is created. In dev mode the app calls `JarvisLog.enableFileLogging(directory:)`,
/// after which `jlog` also appends to `<directory>/jarvis-debug.log` (created `0600`, truncated
/// fresh for the session). This keeps screen-derived coaching text out of any world-readable or
/// persistent file outside dev mode — see wiki/sandbox.md ("no recording to disk").
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

/// Lightweight logger: always writes to the unified log (Console) and mirrors into the dev activity
/// viewer; additionally appends to the dev debug file when file logging is enabled.
/// `image`, when set, is a base64-encoded JPEG screenshot to show as a thumbnail in the dev activity
/// viewer (the file log and unified log stay text-only).
public func jlog(_ message: String, image base64JPEG: String? = nil) {
    NSLog("%@", message)
    ActivityLog.shared.record(message, imageBase64: base64JPEG)  // dev-only HTML viewer (no-op when disabled)

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
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}
