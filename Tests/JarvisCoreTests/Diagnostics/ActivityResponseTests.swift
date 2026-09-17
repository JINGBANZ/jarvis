import Foundation
import Testing
@testable import JarvisCore

@Suite struct ActivityResponseTests {
    @Test func deliveredPartsSurviveLiveReplayPersistenceAndMixedHistory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)
        let detail = "The caller needs a result.\n\n```python\nif ready:\n    return values\n```"
        evidence.record(.tip(lines: ["Return the values."], detail: detail))
        _ = await evidence.close()
        let live = log.attach { _ in }
        let script = try #require(live.rows.first)
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(script.dropFirst("appendRow(".count).dropLast(2).utf8)) as? [String: Any])
        let response = try #require(object["response"] as? [String: Any])
        #expect(response["lines"] as? [String] == ["Return the values."])
        #expect(response["detail"] as? String == detail)

        let session = SessionStore.Session(id: "2026-09-10_00-00-00_abcd", label: "test", url: dir,
                                           isCurrent: false, evidenceIsComplete: true)
        let store = SessionStore(base: dir.deletingLastPathComponent(), current: nil)
        let reloaded = try #require(store.entries(for: session).first?.0)
        #expect(reloaded.response?.detail == detail)
        #expect(reloaded.response?.explanation == nil)
        #expect(reloaded.response?.code == nil)
        #expect(reloaded.message.contains("\n\nDetail\n"))

        let file = dir.appendingPathComponent(ActivityLog.filename)
        var data = try Data(contentsOf: file)
        data.append(Data(#"{"t":"00:00:01","m":"💬 legacy hint"}"#.utf8))
        data.append(0x0a)
        try data.write(to: file)
        let mixed = store.entries(for: session)
        #expect(mixed.count == 2)
        #expect(mixed[0].0.response == reloaded.response)
        #expect(mixed[1].0.response == nil)
        #expect(mixed[1].0.message == "💬 legacy hint")
    }

    @Test func exportsKeepSectionsIndentationAndLiteralMarkup() throws {
        let response = ActivityResponse(
            lines: ["Inspect <input>."],
            detail: "Keep <tags> literal.\n\n```html\n  <script>literal()</script>\n```")
        let entry = ActivityLog.Entry(time: "00:00", message: response.message, imageFile: nil,
                                      response: response)
        let session = SessionStore.Session(id: "test", label: "test", url: URL(fileURLWithPath: "/tmp/test"),
                                           isCurrent: false, evidenceIsComplete: true)
        func export(_ format: ActivityHistoryExporter.ExportFormat) -> String {
            ActivityHistoryExporter.export(session: session, entries: [(entry, nil)], format: format,
                includeScreenshots: false, jarvisResponsesOnly: true).text
        }
        let markdown = export(.markdown)
        #expect(markdown.contains("### Hint\n"))
        #expect(markdown.contains("### Detail\n"))
        #expect(!markdown.contains("### Explanation\n"))
        #expect(markdown.contains("```html\n  <script>literal()</script>\n```"))
        let text = export(.plainText)
        #expect(text.contains("\n\nDetail\n"))
        #expect(text.contains("  <script>literal()</script>"))
        let html = export(.html)
        #expect(html.contains("<h3>Detail</h3>"))
        #expect(html.contains("&lt;script&gt;literal()&lt;/script&gt;"))
        #expect(!html.contains("<script>"))
    }

    @Test func aRowWrittenBeforeTheDetailBoxStillExportsItsOwnSections() throws {
        let legacy = try JSONDecoder().decode(ActivityResponse.self, from: Data("""
            {"lines":["Return the values."],
             "explanation":"The caller needs a result.",
             "code":{"language":"python","placement":"After the loop","code":"return best"}}
            """.utf8))
        #expect(legacy.detail == nil)
        #expect(legacy.message.contains("\n\nExplanation\n"))
        let entry = ActivityLog.Entry(time: "00:00", message: legacy.message, imageFile: nil,
                                      response: legacy)
        let session = SessionStore.Session(id: "test", label: "test", url: URL(fileURLWithPath: "/tmp/test"),
                                           isCurrent: false, evidenceIsComplete: true)
        let markdown = ActivityHistoryExporter.export(
            session: session, entries: [(entry, nil)], format: .markdown,
            includeScreenshots: false, jarvisResponsesOnly: true).text
        #expect(markdown.contains("### Explanation\n"))
        #expect(markdown.contains("### Code\n"))
        #expect(!markdown.contains("### Detail\n"))
    }
}
