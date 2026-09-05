import Foundation

/// Turns one session's already-decoded Activity entries into an exportable document, for the
/// "Export…" action in `ActivityViewer` (JarvisApp). Foundation-only and pure — this type never
/// touches disk; the caller decides where to write `text` and each `images` pair.
public enum ActivityHistoryExporter {
    public enum ExportFormat: String, CaseIterable, Sendable {
        case markdown, plainText, html
    }

    public struct Export: Sendable {
        public let filename: String
        public let text: String
        public let images: [(filename: String, data: Data)]
    }

    public static func export(
        session: SessionStore.Session,
        entries: [(ActivityLog.Entry, Data?)],
        format: ExportFormat,
        includeScreenshots: Bool,
        jarvisResponsesOnly: Bool
    ) -> Export {
        let kept = jarvisResponsesOnly ? responsesOnly(entries) : entries
        let suffix = jarvisResponsesOnly ? "-jarvis-only" : ""

        switch format {
        case .markdown:
            return Export(
                filename: "activity\(suffix).md",
                text: markdown(session: session, entries: kept, includeScreenshots: includeScreenshots),
                images: images(for: kept, includeScreenshots: includeScreenshots))
        case .plainText:
            return Export(
                filename: "activity\(suffix).txt",
                text: plainText(session: session, entries: kept, includeScreenshots: includeScreenshots),
                images: images(for: kept, includeScreenshots: includeScreenshots))
        case .html:
            return Export(
                filename: "activity\(suffix).html",
                text: html(session: session, entries: kept, includeScreenshots: includeScreenshots),
                images: [])
        }
    }

    /// The `ActivityLog.cssClass` values counted as "Jarvis's own actions" for the
    /// responses-only filter — today, its spoken tips (💬 `say`) and its screen views (👁 `see`).
    /// Add another class here to broaden the filter later; nothing else needs to change.
    private static let jarvisResponseClasses: Set<String> = ["say", "see"]

    /// Keeps only Jarvis's own actions (`jarvisResponseClasses`), dropping heard speech and
    /// system/lifecycle notices. Independent of `includeScreenshots`: whether a kept screen-view
    /// row's own image is actually exported is decided later, purely by that other toggle, with
    /// no cross-referencing here.
    private static func responsesOnly(
        _ entries: [(ActivityLog.Entry, Data?)]
    ) -> [(ActivityLog.Entry, Data?)] {
        entries.filter { jarvisResponseClasses.contains(ActivityLog.cssClass(for: $0.0.message)) }
    }

    private static func images(
        for entries: [(ActivityLog.Entry, Data?)],
        includeScreenshots: Bool
    ) -> [(filename: String, data: Data)] {
        guard includeScreenshots else { return [] }
        return entries.compactMap { entry, data in
            guard let imageFile = entry.imageFile, let data else { return nil }
            return ("images/\(imageFile)", data)
        }
    }

    private static func markdown(
        session: SessionStore.Session,
        entries: [(ActivityLog.Entry, Data?)],
        includeScreenshots: Bool
    ) -> String {
        var lines = ["# Jarvis session — \(session.label)", "", "Session ID: \(session.id)", ""]
        for (entry, data) in entries {
            lines.append("**\(entry.time)** — \(entry.message)")
            if includeScreenshots, let imageFile = entry.imageFile, data != nil {
                lines.append("")
                lines.append("![screenshot](images/\(imageFile))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func plainText(
        session: SessionStore.Session,
        entries: [(ActivityLog.Entry, Data?)],
        includeScreenshots: Bool
    ) -> String {
        var lines = ["Jarvis session — \(session.label)", "Session ID: \(session.id)", ""]
        for (entry, data) in entries {
            lines.append("\(entry.time)  \(entry.message)")
            if includeScreenshots, let imageFile = entry.imageFile, data != nil {
                lines.append("[screenshot: images/\(imageFile)]")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func html(
        session: SessionStore.Session,
        entries: [(ActivityLog.Entry, Data?)],
        includeScreenshots: Bool
    ) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var rows = ""
        for (entry, data) in entries {
            rows += "<div class=\"row\"><span class=\"t\">\(escape(entry.time))</span>"
            rows += "<span class=\"m\">\(escape(entry.message))"
            if includeScreenshots, let data {
                rows += "<img src=\"data:image/jpeg;base64,\(data.base64EncodedString())\">"
            }
            rows += "</span></div>\n"
        }
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <title>Jarvis session — \(escape(session.label))</title>
        <style>
          body { font: 13px/1.5 -apple-system, sans-serif; margin: 24px; }
          .row { display: grid; grid-template-columns: 70px 1fr; gap: 12px; padding: 6px 0; }
          .t { color: #888; }
          img { display: block; max-width: 480px; margin-top: 8px; border-radius: 6px; }
        </style></head><body>
        <h1>Jarvis session — \(escape(session.label))</h1>
        <p>Session ID: \(escape(session.id))</p>
        \(rows)
        </body></html>
        """
    }
}
