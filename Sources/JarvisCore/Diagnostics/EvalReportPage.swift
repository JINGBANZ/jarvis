import Foundation

/// Renders a saved evaluation report (`eval-report.md`) as a self-contained HTML page so "Open
/// report" can hand it to the user's browser. The markdown stays the on-disk source of truth — it's
/// what both evaluators produce and what an agent consumes when the user pastes the report into a
/// fix-it chat — so the page embeds the raw markdown verbatim behind a **Copy as Markdown** button,
/// and the HTML is a derived view regenerated from the markdown on every open (never stale after an
/// agentic re-audit rewrites the `.md`).
///
/// The renderer is a deliberate subset of markdown — headings, lists, tables, fenced code,
/// blockquotes, bold / inline code / links — which covers the report skeleton `SessionEvaluator` and
/// `AgenticEvaluation` prescribe. Anything it renders imperfectly is still recoverable via the
/// embedded raw markdown. All report content is HTML-escaped: the report is LLM output and must not
/// be able to inject script into a local page.
public enum EvalReportPage {
    /// Written beside `eval-report.md` in the session directory, owner-only like everything there.
    public static let filename = "eval-report.html"

    /// Render `markdown` and write the page into the session directory (owner-only). Returns the
    /// page's URL for handing to the browser.
    @discardableResult
    public static func write(markdown: String, in sessionDir: URL, title: String) throws -> URL {
        let url = sessionDir.appendingPathComponent(filename)
        let ok = FileManager.default.createFile(
            atPath: url.path,
            contents: Data(render(markdown: markdown, title: title).utf8),
            attributes: [.posixPermissions: 0o600])
        guard ok else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    // MARK: - Page assembly

    static func render(markdown: String, title: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px/1.6 -apple-system, system-ui, sans-serif;
                 max-width: 760px; margin: 2rem auto 4rem; padding: 0 1.5rem; }
          header { display: flex; justify-content: space-between; align-items: baseline; gap: 1rem; }
          header h1 { font-size: 1.4rem; }
          h2 { border-bottom: 1px solid rgba(127,127,127,.35); padding-bottom: .2em; margin-top: 2em; }
          code { font-family: ui-monospace, monospace; font-size: .9em;
                 background: rgba(127,127,127,.15); padding: .1em .3em; border-radius: 4px; }
          pre { background: rgba(127,127,127,.12); padding: .8em 1em; border-radius: 8px; overflow-x: auto; }
          pre code { background: none; padding: 0; }
          table { border-collapse: collapse; margin: 1em 0; }
          th, td { border: 1px solid rgba(127,127,127,.4); padding: .3em .6em; text-align: left; }
          blockquote { border-left: 3px solid rgba(127,127,127,.4); margin-left: 0;
                       padding-left: 1em; opacity: .75; }
          #copy { font: inherit; padding: .35em .8em; border-radius: 6px;
                  border: 1px solid rgba(127,127,127,.5); background: rgba(127,127,127,.12);
                  cursor: pointer; white-space: nowrap; }
          #copy:hover { background: rgba(127,127,127,.25); }
        </style>
        </head>
        <body>
        <header>
        <h1>\(escape(title))</h1>
        <button id="copy" title="Copy the raw markdown report — paste it into an agent chat to work on the findings">Copy as Markdown</button>
        </header>
        \(body(from: markdown))
        <textarea id="md" hidden readonly>\(escape(markdown))</textarea>
        <script>
        const btn = document.getElementById("copy"), ta = document.getElementById("md");
        btn.addEventListener("click", async () => {
          try { await navigator.clipboard.writeText(ta.value); }
          catch {
            ta.hidden = false; ta.select();
            if (document.execCommand("copy")) { ta.hidden = true; }
            else { btn.textContent = "Copy failed — press ⌘C"; return; }   // markdown left selected
          }
          btn.textContent = "Copied ✓";
          setTimeout(() => { btn.textContent = "Copy as Markdown"; }, 1500);
        });
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Markdown → HTML (subset)

    static func body(from markdown: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var listTag: String?
        var tableRows: [[String]] = []
        var inCode = false
        var codeLines: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            html.append("<blockquote><p>\(inline(quote.joined(separator: " ")))</p></blockquote>")
            quote = []
        }
        func flushList() {
            guard let tag = listTag else { return }
            html.append("</\(tag)>")
            listTag = nil
        }
        func flushTable() {
            guard !tableRows.isEmpty else { return }
            var rows = tableRows
            tableRows = []
            var out = ["<table>"]
            // A dashes-only second row is the markdown header separator.
            let hasHeader = rows.count >= 2
                && rows[1].allSatisfy { $0.allSatisfy { "-: ".contains($0) } && $0.contains("-") }
            if hasHeader {
                let header = rows.removeFirst()
                rows.removeFirst()
                out.append("<tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr>")
            }
            for row in rows {
                out.append("<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>")
            }
            out.append("</table>")
            html.append(out.joined())
        }
        func flushBlocks() {
            flushParagraph()
            flushQuote()
            flushList()
            flushTable()
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if inCode {
                if line.hasPrefix("```") {
                    html.append("<pre><code>\(escape(codeLines.joined(separator: "\n")))</code></pre>")
                    codeLines = []
                    inCode = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            if line.hasPrefix("```") {
                flushBlocks()
                inCode = true
            } else if line.isEmpty {
                flushBlocks()
            } else if let heading = headingLevel(of: line) {
                flushBlocks()
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                html.append("<h\(heading)>\(inline(text))</h\(heading)>")
            } else if line.allSatisfy({ $0 == "-" }), line.count >= 3 {
                flushBlocks()
                html.append("<hr>")
            } else if line.hasPrefix("|") {
                flushParagraph(); flushQuote(); flushList()
                tableRows.append(
                    line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) })
            } else if let item = listItem(of: line) {
                flushParagraph(); flushQuote(); flushTable()
                if listTag != item.tag {
                    flushList()
                    listTag = item.tag
                    html.append("<\(item.tag)>")
                }
                html.append("<li>\(inline(item.text))</li>")
            } else if line.hasPrefix(">") {
                flushParagraph(); flushList(); flushTable()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else {
                flushQuote(); flushList(); flushTable()
                paragraph.append(line)
            }
        }
        flushBlocks()
        if inCode {   // unclosed fence: still show what was collected
            html.append("<pre><code>\(escape(codeLines.joined(separator: "\n")))</code></pre>")
        }
        return html.joined(separator: "\n")
    }

    private static func headingLevel(of line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...4).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(of line: String) -> (tag: String, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return ("ul", String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return ("ol", String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    /// Inline markdown on already block-split text: escape first (LLM output must never reach the
    /// page unescaped), then code spans, bold, and links.
    private static func inline(_ text: String) -> String {
        var s = escape(text)
        s = s.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "<strong>$1</strong>",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)\\s\"]+)\\)",
                                   with: "<a href=\"$2\">$1</a>",
                                   options: .regularExpression)
        return s
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
