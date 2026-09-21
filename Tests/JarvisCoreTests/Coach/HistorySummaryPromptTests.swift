import Foundation
import Testing
@testable import JarvisCore

@Suite struct HistorySummaryPromptTests {
    @Test func inputPreservesAdviceAndSeparatesHistoricalEvidence() throws {
        let input = try JarvisPrompts.HistorySummary.input([
            .user("Give me a hint about the screenshot."),
            .assistantToolCalls([.init(id: "reply", name: "speak", argumentsJSON:
                #"{"lines":["Keep boundary events."],"detail":"Use < cutoff, then test equality."}"#)]),
            .init(role: .tool, text: "shown to the user", toolCallId: "reply"),
            .user(JarvisPrompts.Coach.earlierImageStub)
        ])
        #expect(input.contains("Keep boundary events."))
        #expect(input.contains("Use < cutoff, then test equality."))
        let records = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [[String: Any]])
        #expect(records[1]["role"] as? String == "assistant")
        let calls = try #require(records[1]["calls"] as? [[String: String]])
        #expect(calls[0]["id"] == "reply")
        #expect(calls[0]["name"] == "speak")
        #expect(records[2]["role"] as? String == "tool")
        #expect(records[2]["toolCallID"] as? String == "reply")
        #expect(records[3]["text"] as? String == JarvisPrompts.Coach.earlierImageStub)
        #expect(records[3]["image"] == nil)
    }

    @Test(arguments: [
        "I can't provide a hint without a screenshot.",
        #"{"context":"Code review"}"#,
        #"{"context":" ","decisions":[],"coaching":[],"openQuestions":[],"verification":[]}"#,
        #"{"context":"Code review","decisions":[],"coaching":false,"openQuestions":[],"verification":[]}"#
    ])
    func invalidBriefingIsRejected(_ output: String) {
        #expect(JarvisPrompts.HistorySummary.validatedSummary(output) == nil)
    }

    @Test func validBriefingRetainsEvidenceStatus() throws {
        let output = #"{"context":"Window review","decisions":["Inclusive boundary"],"coaching":["Trace equal timestamps"],"openQuestions":["Cooldown scope unknown"],"verification":["Patch accepted; test output not observed"]}"#
        let summary = try #require(JarvisPrompts.HistorySummary.validatedSummary(output))
        #expect(summary.contains("test output not observed"))
        #expect(summary.contains("Cooldown scope unknown"))
    }

    @Test func fencedBriefingIsValidatedAndNormalized() throws {
        let json = #"{"context":"Window review","decisions":[],"coaching":[],"openQuestions":[],"verification":[],"extra":"discard me"}"#
        let summary = try #require(JarvisPrompts.HistorySummary.validatedSummary("```json\n" + json + "\n```"))
        #expect(!summary.contains("```"))
        #expect(!summary.contains("discard me"))
        #expect(JarvisPrompts.HistorySummary.validatedSummary("Here is the summary:\n```json\n" + json + "\n```") == nil)
        #expect(JarvisPrompts.HistorySummary.validatedSummary("```json\n" + json) == nil)
        #expect(JarvisPrompts.HistorySummary.validatedSummary("```json\n" + json + "\n```\nDone") == nil)
    }

    @Test(arguments: ["", "json", "JSON", "JsOn"], ["\n", "\r\n"])
    func commonWholeResponseFencesPreserveBriefingEvidence(_ tag: String, _ newline: String) throws {
        let json = #"{"context":"Window review","decisions":[],"coaching":[],"openQuestions":[],"verification":["Tests not observed"]}"#
        let wrapped = "```" + tag + newline + json + newline + "```"
        let summary = try #require(JarvisPrompts.HistorySummary.validatedSummary(wrapped))
        let briefing = try #require(JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any])
        #expect(briefing["context"] as? String == "Window review")
        #expect(briefing["verification"] as? [String] == ["Tests not observed"])
    }

    @Test(arguments: ["", "JSON"], [
        #"{"context":"Window review"}"#,
        #"{"context":" ","decisions":[],"coaching":[],"openQuestions":[],"verification":[]}"#,
        #"{"context":"Window review","decisions":[],"coaching":[],"openQuestions":[],"verification":false}"#,
        #"{"context":"Window review","decisions":[],"coaching":[],"openQuestions":[],"verification":[]"#
    ])
    func commonFencesDoNotRelaxBriefingValidation(_ tag: String, _ json: String) {
        #expect(JarvisPrompts.HistorySummary.validatedSummary("```" + tag + "\r\n" + json + "\r\n```") == nil)
    }

    @Test(arguments: ["python", "json extra"])
    func unrelatedFenceTagsAreRejected(_ tag: String) {
        let json = #"{"context":"Window review","decisions":[],"coaching":[],"openQuestions":[],"verification":[]}"#
        #expect(JarvisPrompts.HistorySummary.validatedSummary("```" + tag + "\n" + json + "\n```") == nil)
    }

    @Test(arguments: [249, 250, 251])
    func briefingWordLimitIncludesEveryField(_ wordCount: Int) throws {
        let fields: [String: Any] = [
            "context": "Window review",
            "decisions": ["Keep evidence"],
            "coaching": ["Explain invariant"],
            "openQuestions": ["Tests pending"],
            "verification": [Array(repeating: "observed", count: wordCount - 8).joined(separator: " ")]
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        #expect((JarvisPrompts.HistorySummary.validatedSummary(json) != nil) == (wordCount < 250))
    }

    @Test(arguments: ["中", "あ", "한"], [749, 750, 751])
    func briefingSizeBoundsUnspacedScripts(_ scalar: String, _ tokens: Int) throws {
        let context = String(repeating: scalar, count: tokens - 20)
        let json = "{\"context\":\"" + context
            + "\",\"decisions\":[],\"coaching\":[],\"openQuestions\":[],\"verification\":[]}"
        #expect((JarvisPrompts.HistorySummary.validatedSummary(json) != nil) == (tokens < 750))
    }

    @Test(arguments: ["decisions", "coaching", "openQuestions", "verification"])
    func briefingSizeIncludesEveryArray(_ field: String) throws {
        var fields: [String: Any] = [
            "context": "Review", "decisions": [], "coaching": [],
            "openQuestions": [], "verification": []
        ]
        fields[field] = [String(repeating: "中", count: 750)]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        #expect(JarvisPrompts.HistorySummary.validatedSummary(json) == nil)
    }

    @Test(arguments: [[String(repeating: "x", count: 3000)], Array(repeating: "", count: 1000)])
    func briefingSizeBoundsLongWordsAndJSONOverhead(_ values: [String]) throws {
        let fields: [String: Any] = [
            "context": "Review", "decisions": values, "coaching": [],
            "openQuestions": [], "verification": []
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        #expect(JarvisPrompts.HistorySummary.validatedSummary(json) == nil)
    }

    @Test func summaryIsFormatNeutralAndRetiresResolvedTopics() {
        let prompt = JarvisPrompts.HistorySummary.system.lowercased()

        #expect(prompt.contains("live coaching session"))
        #expect(prompt.contains("participants and goal"))
        #expect(prompt.contains("resolved topics"))
        #expect(prompt.contains("omit obsolete detail"))
        #expect(prompt.contains("do not assume a coding interview"))
        #expect(!prompt.contains("coding-interview coaching session"))
    }
}
