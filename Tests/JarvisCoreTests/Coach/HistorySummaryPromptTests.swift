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
            .userImage("PRIVATE_PIXELS")
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
        #expect(!input.contains("PRIVATE_PIXELS"))
        #expect(input.contains("omitted"))
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
