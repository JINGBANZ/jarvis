import Foundation

/// Mirrors every `jlog` line into a self-contained, auto-refreshing HTML file so you can *watch*
/// Jarvis think in a browser instead of tailing a flat file. Open it once:
///
///     open /tmp/jarvis-activity.html
///
/// The page reloads itself every second and scrolls to the newest line. No server, no dependencies
/// — it works straight off `file://`. Path overridable via `JARVIS_ACTIVITY_HTML`.
public final class ActivityLog: @unchecked Sendable {
    public static let shared = ActivityLog()

    private let path: String
    private let maxLines = 400
    private let queue = DispatchQueue(label: "jarvis.activitylog")   // serializes state + disk writes
    private var lines: [(time: String, message: String)] = []
    private let df: DateFormatter

    private init() {
        path = ProcessInfo.processInfo.environment["JARVIS_ACTIVITY_HTML"] ?? "/tmp/jarvis-activity.html"
        df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
    }

    /// Where the live HTML page is written — open this in a browser.
    public var htmlURL: URL { URL(fileURLWithPath: path) }

    /// Clear the buffer and write a fresh page. Call at launch so each session starts clean
    /// (the file exists before we open it in the browser — written synchronously).
    public func reset() {
        queue.sync {
            lines.removeAll()
            writeHTML()
        }
    }

    /// Append a line and rewrite the HTML. Cheap and off the caller's thread.
    public func record(_ message: String, at date: Date = Date()) {
        queue.async { [self] in
            lines.append((df.string(from: date), message))
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            writeHTML()
        }
    }

    private func writeHTML() {
        var rows = ""
        for line in lines {
            rows += "<div class=\"row \(cssClass(for: line.message))\">"
            rows += "<span class=\"t\">\(esc(line.time))</span>"
            rows += "<span class=\"m\">\(esc(line.message))</span></div>\n"
        }
        let html = """
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8">
        <meta http-equiv="refresh" content="1">
        <title>Jarvis Activity</title>
        <style>
          :root { color-scheme: dark; }
          body { margin: 0; background: #0d1117; color: #c9d1d9;
                 font: 13px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; }
          header { position: sticky; top: 0; padding: 10px 16px; background: #161b22;
                   border-bottom: 1px solid #30363d; font-weight: 600; }
          header .count { color: #8b949e; font-weight: 400; }
          main { padding: 8px 16px 40px; }
          .row { display: flex; gap: 12px; padding: 1px 0; white-space: pre-wrap; }
          .t { color: #6e7681; flex: 0 0 auto; }
          .m { flex: 1 1 auto; }
          .say .m  { color: #3fb950; }   /* spoke              */
          .see .m  { color: #d29922; }   /* looked at screen   */
          .hear .m { color: #58a6ff; }   /* heard you          */
          .think .m{ color: #8b949e; }   /* thinking / silent  */
          .err .m  { color: #f85149; }   /* error              */
        </style></head><body>
        <header>🟢 Jarvis — live activity <span class="count">(\(lines.count) lines)</span></header>
        <main>\(rows)</main>
        <script>window.scrollTo(0, document.body.scrollHeight);</script>
        </body></html>
        """
        try? html.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Map a line to a colour class by its leading marker / keywords.
    private func cssClass(for message: String) -> String {
        let m = message.lowercased()
        if m.contains("error") || m.contains("failed") || m.contains("denied") { return "err" }
        if message.contains("💬") { return "say" }
        if message.contains("👁") { return "see" }
        if message.contains("🗣") || message.contains("🤫") { return "hear" }
        if message.contains("💭") || m.contains("stay") || m.contains("held back") { return "think" }
        return ""
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
