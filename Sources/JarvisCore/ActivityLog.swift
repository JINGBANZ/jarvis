import Foundation

/// Mirrors `jlog` lines into a self-contained, auto-refreshing HTML page so you can *watch* Jarvis
/// think in a browser. **Dev-mode only:** until `enable(directory:)` is called (or the
/// `JARVIS_ACTIVITY_HTML` env override is set) `record(_:)` is a no-op and nothing is written to
/// disk. When enabled it writes `<directory>/jarvis-activity.html` with `0600` permissions (owner
/// only), fresh each session — so the model's screen-derived tips never land in a world-readable or
/// persistent location. See wiki/sandbox.md.
public final class ActivityLog: @unchecked Sendable {
    public static let shared = ActivityLog()

    /// One rendered row: a timestamped message, optionally with a screenshot thumbnail. `imageFile`
    /// is the relative filename of the saved JPEG (e.g. `shot-3.jpg`), or nil for a plain text line.
    struct Entry {
        let time: String
        let message: String
        let imageFile: String?
    }

    private let maxLines = 400
    private let queue = DispatchQueue(label: "jarvis.activitylog")   // serializes state + disk writes
    private var entries: [Entry] = []
    private var shotSeq = 0       // monotonic id for saved screenshot files this session
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
            entries.removeAll()
            shotSeq = 0
            writeHTML()
        }
    }

    /// Turn the viewer back off (no further disk writes). Mainly for tests that drive the shared
    /// singleton and need to reset it afterwards so they don't leak state into other tests.
    func disable() {
        queue.sync { fileURL = nil; entries.removeAll(); shotSeq = 0 }
    }

    /// The HTML page to open in a browser, or nil when logging is disabled.
    public var htmlURL: URL? { queue.sync { fileURL } }

    /// Append a line and rewrite the HTML. No-op (and no disk write) when disabled.
    ///
    /// When `imageBase64` is a base64-encoded JPEG (a screenshot the model just looked at), it's
    /// saved next to the HTML as an owner-only `shot-N.jpg` and shown as a clickable thumbnail —
    /// so the activity log captures the *visual* part of the interaction, not just the text.
    public func record(_ message: String, imageBase64: String? = nil, at date: Date = Date()) {
        queue.async { [self] in
            guard let dir = fileURL?.deletingLastPathComponent() else { return }
            let imageFile = imageBase64.flatMap { saveShot($0, in: dir) }
            entries.append(Entry(time: df.string(from: date), message: message, imageFile: imageFile))
            if entries.count > maxLines { entries.removeFirst(entries.count - maxLines) }
            writeHTML()
        }
    }

    /// Decode a base64 JPEG and write it as the next owner-only `shot-N.jpg` in `dir`. Returns the
    /// relative filename to reference from the HTML, or nil if the payload wasn't valid. Must run on
    /// `queue` (mutates `shotSeq`).
    private func saveShot(_ base64: String, in dir: URL) -> String? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        shotSeq += 1
        let name = "shot-\(shotSeq).jpg"
        FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path,
                                       contents: data, attributes: [.posixPermissions: 0o600])
        return name
    }

    private func writeHTML() {
        guard let url = fileURL, let data = Self.renderHTML(entries).data(using: .utf8) else { return }
        // createFile (not atomic write) so we can set 0600 in one step — owner-only, never 0644.
        FileManager.default.createFile(atPath: url.path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }

    // MARK: - Pure rendering (testable without disk)

    static func renderHTML(_ entries: [Entry]) -> String {
        var rows = ""
        for entry in entries {
            rows += "<div class=\"row \(cssClass(for: entry.message))\">"
            rows += "<span class=\"t\">\(esc(entry.time))</span>"
            rows += "<span class=\"m\">\(esc(entry.message))"
            if let file = entry.imageFile {
                // Thumbnail links to the full-size JPEG in a new tab — the activity page reloads
                // every 1s, so an inline lightbox would collapse; a separate tab survives.
                rows += "<a class=\"shot\" href=\"\(esc(file))\" target=\"_blank\" rel=\"noopener\">"
                rows += "<img src=\"\(esc(file))\" alt=\"screenshot\" loading=\"lazy\"></a>"
            }
            rows += "</span></div>\n"
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
          .shot { display: block; margin-top: 4px; width: fit-content; }
          .shot img { display: block; max-height: 140px; max-width: 280px;
                      border: 1px solid #30363d; border-radius: 6px; cursor: zoom-in; }
        </style></head><body>
        <header>Jarvis — activity log <span class="count">(\(entries.count) lines)</span></header>
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
