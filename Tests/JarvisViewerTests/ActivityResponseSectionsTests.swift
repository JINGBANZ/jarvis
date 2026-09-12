import Testing
import WebKit
@testable import JarvisCore

@Suite(.serialized) struct ActivityResponseSectionsTests {
    @MainActor @Test func separatesResponsePartsAndPreservesLiteralCode() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        let snippet = try #require(CodeSnippet(language: "python", placement: "After the while loop",
            code: "if value < 2:\n    return \"<script>bad()</script>\""))
        try await h.eval(ActivityLog.rowScript(time: "12:00", message: "legacy fallback", imageBase64: nil,
            response: ActivityResponse(lines: ["Return result after the loop."],
                explanation: "The caller otherwise receives None.", codeSnippet: snippet)))
        let headings = try await h.eval(
            "Array.from(document.querySelectorAll('.response-section h3')).map(x=>x.textContent).join('|')"
        ) as? String
        #expect(headings == "Hint|Explanation|Code")
        let code = try await h.eval("document.querySelector('.response-section pre code')?.textContent") as? String
        #expect(code == "if value < 2:\n    return \"<script>bad()</script>\"")
        let injected = try await h.eval("document.querySelectorAll('#log script').length") as? Int
        #expect(injected == 0)
        let text = try await h.eval("document.querySelector('#log').textContent") as? String
        #expect(text?.contains("After the while loop") == true)
        #expect(text?.contains("legacy fallback") == false)
    }

    @MainActor @Test func ordinaryHintOmitsEmptyExplanationAndCodeSections() async throws {
        let h = WebViewHarness()
        try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(time: "12:00", message: "💬 Return result.", imageBase64: nil,
            response: ActivityResponse(lines: ["Return result."], explanation: "  ")))
        let headings = try await h.eval(
            "Array.from(document.querySelectorAll('.response-section h3')).map(x=>x.textContent).join('|')"
        ) as? String
        #expect(headings == "Hint")
        let text = try await h.eval("document.querySelector('#log').textContent") as? String
        #expect(text?.contains("Return result.") == true)
    }
}
