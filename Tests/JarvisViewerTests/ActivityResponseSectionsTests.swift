import Testing
import WebKit
@testable import JarvisCore

@Suite(.serialized) struct ActivityResponseSectionsTests {
    @MainActor @Test func separatesResponsePartsAndPreservesLiteralCode() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(time: "12:00", message: "legacy fallback", imageBase64: nil,
            response: ActivityResponse(lines: ["Return result after the loop."],
                detail: "The caller otherwise receives None.\n\n```python\nif value < 2:\n"
                    + "    return \"<script>bad()</script>\"\n```")))
        let headings = try await h.eval(
            "Array.from(document.querySelectorAll('.response-section h3')).map(x=>x.textContent).join('|')"
        ) as? String
        #expect(headings == "Hint|Detail")
        let injected = try await h.eval("document.querySelectorAll('#log script').length") as? Int
        #expect(injected == 0)
        let text = try await h.eval("document.querySelector('#log').textContent") as? String
        // The detail is Markdown, written out verbatim; the fence and its literal code survive.
        #expect(text?.contains("return \"<script>bad()</script>\"") == true)
        #expect(text?.contains("legacy fallback") == false)
    }

    @MainActor @Test func ordinaryHintOmitsTheDetailSection() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(time: "12:00", message: "💬 Return result.", imageBase64: nil,
            response: ActivityResponse(lines: ["Return result."], detail: "  ")))
        let headings = try await h.eval(
            "Array.from(document.querySelectorAll('.response-section h3')).map(x=>x.textContent).join('|')"
        ) as? String
        #expect(headings == "Hint")
        let text = try await h.eval("document.querySelector('#log').textContent") as? String
        #expect(text?.contains("Return result.") == true)
    }

    /// A session recorded before the detail box still opens with the sections it was written with.
    @MainActor @Test func aRowWrittenBeforeTheDetailBoxStillRendersBothOldSections() async throws {
        let legacy = try #require(try? JSONDecoder().decode(ActivityResponse.self, from: Data("""
            {"lines":["Return result after the loop."],
             "explanation":"The caller otherwise receives None.",
             "code":{"language":"python","placement":"After the while loop","code":"return best"}}
            """.utf8)))
        #expect(legacy.detail == nil)
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(time: "12:00", message: "legacy fallback",
                                               imageBase64: nil, response: legacy))
        let headings = try await h.eval(
            "Array.from(document.querySelectorAll('.response-section h3')).map(x=>x.textContent).join('|')"
        ) as? String
        #expect(headings == "Hint|Explanation|Code")
        let code = try await h.eval("document.querySelector('.response-section pre code')?.textContent") as? String
        #expect(code == "return best")
        let text = try await h.eval("document.querySelector('#log').textContent") as? String
        #expect(text?.contains("After the while loop") == true)
    }
}
