import Testing
@testable import JarvisCore

@Suite struct HistorySummaryPromptTests {
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
