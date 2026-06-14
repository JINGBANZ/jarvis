import Foundation

/// Lightweight logger: writes to the unified log (Console) AND appends to a file, so logs are
/// readable no matter how the app is launched (LaunchServices `open` vs. direct exec). The file
/// path can be overridden with the `JARVIS_LOG` env var; defaults to /tmp/jarvis-debug.log.
public func jlog(_ message: String) {
    NSLog("%@", message)
    ActivityLog.shared.record(message)        // mirror into the live HTML viewer
    let path = ProcessInfo.processInfo.environment["JARVIS_LOG"] ?? "/tmp/jarvis-debug.log"
    let line = "\(Self_timestamp()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: path)
    if let fh = try? FileHandle(forWritingTo: url) {
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}

private func Self_timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}
