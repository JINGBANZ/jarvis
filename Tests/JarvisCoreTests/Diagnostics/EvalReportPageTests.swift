import Foundation
import Testing

@testable import JarvisCore

@Suite("EvalReportPage")
struct EvalReportPageTests {
    // MARK: - Block rendering

    @Test func rendersTheReportSkeleton() {
        let markdown = """
        ## Context engineering
        Prompts grew from **1.2k** to `4.9k` tokens (call #3).

        ## Recommendations
        1. [confirmed] Stub screenshots at commit.
        2. [hypothesis] Pin `prompt_cache_key`.

        - first bullet
        - second bullet
        """
        let body = EvalReportPage.body(from: markdown)
        #expect(body.contains("<h2>Context engineering</h2>"))
        #expect(body.contains("<strong>1.2k</strong>"))
        #expect(body.contains("<code>4.9k</code>"))
        #expect(body.contains("<ol>"))
        #expect(body.contains("<li>[confirmed] Stub screenshots at commit.</li>"))
        #expect(body.contains("<ul>"))
        #expect(body.contains("<li>first bullet</li>"))
    }

    @Test func rendersFencedCodeVerbatimAndEscaped() {
        let body = EvalReportPage.body(from: "```\nlet a = b < c && d\n```")
        #expect(body.contains("<pre><code>let a = b &lt; c &amp;&amp; d</code></pre>"))
    }

    @Test func rendersTablesWithHeaderSeparator() {
        let body = EvalReportPage.body(from: """
        | call | cached |
        | --- | --- |
        | #1 | 0 |
        """)
        #expect(body.contains("<th>call</th>"))
        #expect(body.contains("<td>#1</td>"))
        #expect(!body.contains("---"))
    }

    @Test func rendersBlockquotesAndLinks() {
        let body = EvalReportPage.body(from: "> see [docs](https://example.com/x)")
        #expect(body.contains("<blockquote>"))
        #expect(body.contains(#"<a href="https://example.com/x">docs</a>"#))
    }

    // MARK: - Injection safety

    @Test func reportContentCannotInjectScript() {
        let hostile = "## <script>alert(1)</script>\n\n<img onerror=x src=y>"
        let page = EvalReportPage.render(markdown: hostile, title: "<script>t</script>")
        #expect(!page.contains("<script>alert(1)</script>"))
        #expect(!page.contains("<img onerror"))
        #expect(!page.contains("<title><script>"))
    }

    // MARK: - The page contract

    @Test func pageEmbedsRawMarkdownBehindTheCopyButton() {
        let markdown = "## Section\n\n- a **finding** with `code`"
        let page = EvalReportPage.render(markdown: markdown, title: "t")
        #expect(page.contains(#"<button id="copy""#))
        #expect(page.contains("navigator.clipboard.writeText"))
        // The textarea holds the markdown verbatim modulo entity escaping, so `.value` (which the
        // browser decodes) round-trips to the exact bytes an agent should receive.
        #expect(page.contains("## Section\n\n- a **finding** with `code`"))
        #expect(page.contains(#"<textarea id="md""#))
    }

    @Test func writeCreatesOwnerOnlyHTMLInTheSessionDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try EvalReportPage.write(markdown: "## Hi", in: dir, title: "Session evaluation — x")
        #expect(url.lastPathComponent == EvalReportPage.filename)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let html = try String(contentsOf: url, encoding: .utf8)
        #expect(html.contains("<h2>Hi</h2>"))
        #expect(html.contains("Session evaluation — x"))
    }
}
