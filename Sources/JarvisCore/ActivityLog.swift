import Foundation

/// Mirrors `jlog` lines into a self-contained, auto-refreshing HTML page so you can *watch* Jarvis
/// think in a browser. **Dev-mode only:** until `enable(directory:)` is called (or the
/// `JARVIS_ACTIVITY_HTML` env override is set) `record(_:)` is a no-op and nothing is written to
/// disk. When enabled it writes `<directory>/jarvis-activity.html` with `0600` permissions (owner
/// only), fresh each session — so the model's screen-derived tips never land in a world-readable or
/// persistent location. See wiki/sandbox.md.
public final class ActivityLog: @unchecked Sendable {
    public static let shared = ActivityLog()

    private let maxLines = 400
    private let queue = DispatchQueue(label: "jarvis.activitylog")   // serializes state + disk writes
    private var lines: [(time: String, message: String)] = []
    private let df: DateFormatter
    private var fileURL: URL?     // nil ⇒ disabled (no disk writes)

    /// Internal so tests can spin up an isolated instance; the app uses `.shared`.
    init() {
        df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        // Headless/test override: a full file path enables logging immediately.
        if let p = ProcessInfo.processInfo.environment["JARVIS_ACTIVITY_HTML"] {
            fileURL = URL(fileURLWithPath: p)
        }
    }

    /// Turn on the viewer for a dev session: write to `<directory>/jarvis-activity.html` at 0600,
    /// cleared fresh. The file exists synchronously on return so the caller can open it.
    public func enable(directory: URL) {
        queue.sync {
            fileURL = directory.appendingPathComponent("jarvis-activity.html")
            lines.removeAll()
            writeHTML()
        }
    }

    /// The HTML page to open in a browser, or nil when logging is disabled.
    public var htmlURL: URL? { queue.sync { fileURL } }

    /// Append a line and rewrite the HTML. No-op (and no disk write) when disabled.
    public func record(_ message: String, at date: Date = Date()) {
        queue.async { [self] in
            guard fileURL != nil else { return }
            lines.append((df.string(from: date), message))
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            writeHTML()
        }
    }

    private func writeHTML() {
        guard let url = fileURL, let data = Self.renderHTML(lines).data(using: .utf8) else { return }
        // createFile (not atomic write) so we can set 0600 in one step — owner-only, never 0644.
        FileManager.default.createFile(atPath: url.path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }

    // MARK: - Pure rendering (testable without disk)

    static func renderHTML(_ lines: [(time: String, message: String)]) -> String {
        var rows = ""
        for line in lines {
            rows += "<div class=\"row \(cssClass(for: line.message))\">"
            rows += "<span class=\"t\">\(esc(line.time))</span>"
            rows += "<span class=\"m\">\(esc(line.message))</span></div>\n"
        }
        return """
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
        <header>Jarvis — activity log <span class="count">(\(lines.count) lines)</span></header>
        <main>\(rows)</main>
        <script>
          // Keep scrollback usable across the 1s reload: only stick to the bottom if the user was
          // already near it; otherwise restore their previous scroll position.
          (function () {
            var KEY = "jarvisActivityScroll";
            var wasAtBottom = sessionStorage.getItem(KEY + ".atBottom");
            var prevTop = sessionStorage.getItem(KEY + ".top");
            if (wasAtBottom === "0" && prevTop !== null) {
              window.scrollTo(0, parseFloat(prevTop));
            } else {
              window.scrollTo(0, document.body.scrollHeight);
            }
            window.addEventListener("scroll", function () {
              var nearBottom = (window.innerHeight + window.scrollY) >= (document.body.scrollHeight - 40);
              sessionStorage.setItem(KEY + ".atBottom", nearBottom ? "1" : "0");
              sessionStorage.setItem(KEY + ".top", String(window.scrollY));
            });
          })();
        </script>
        </body></html>
        """
    }

    /// Colour class keyed on the line's **leading marker** (the intentional emoji prefix), not a
    /// substring match anywhere — so a coaching tip that happens to contain "failed" isn't
    /// mis-coloured as an error.
    static func cssClass(for message: String) -> String {
        let m = message.trimmingCharacters(in: .whitespaces)
        if m.hasPrefix("💬") { return "say" }
        if m.hasPrefix("👁") { return "see" }
        if m.hasPrefix("🗣") || m.hasPrefix("🤫") { return "hear" }
        if m.hasPrefix("💭") || m.hasPrefix("…") { return "think" }
        let low = m.lowercased()
        if low.contains("error") || low.contains("failed") || low.contains("denied") { return "err" }
        return ""
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
