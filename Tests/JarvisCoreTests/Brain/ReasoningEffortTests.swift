import Testing
@testable import JarvisCore

@Suite struct ReasoningEffortTests {
    @Test func hasExactlyTheFourSupportedLevelsInOrder() {
        #expect(ReasoningEffort.allCases == [.none, .low, .medium, .high])
    }

    @Test func rawValuesAreTheAPIStrings() {
        #expect(ReasoningEffort.none.rawValue == "none")
        #expect(ReasoningEffort.low.rawValue == "low")
        #expect(ReasoningEffort.medium.rawValue == "medium")
        #expect(ReasoningEffort.high.rawValue == "high")
    }

    /// A provider floor is `max(selected, floor)`, so the order must be the declaration order.
    @Test func ordersByDepth() {
        #expect(ReasoningEffort.none < .low)
        #expect(ReasoningEffort.low < .medium)
        #expect(ReasoningEffort.medium < .high)
        #expect(ReasoningEffort.allCases.sorted() == ReasoningEffort.allCases)
        #expect(max(ReasoningEffort.none, .low) == .low)
    }

    @Test func defaultIsLow() {
        #expect(Defaults.Brain.effort == .low)
    }

    /// 25k is OpenAI's recommended reasoning reserve; a flat 768 cap truncated high-effort
    /// reasoning.
    @Test func maxOutputTokensScalesWithEffort() {
        #expect(ReasoningEffort.none.maxOutputTokens < ReasoningEffort.low.maxOutputTokens)
        #expect(ReasoningEffort.low.maxOutputTokens < ReasoningEffort.medium.maxOutputTokens)
        #expect(ReasoningEffort.medium.maxOutputTokens < ReasoningEffort.high.maxOutputTokens)
        #expect(ReasoningEffort.high.maxOutputTokens >= 25_000)
        for e in ReasoningEffort.allCases { #expect(e.maxOutputTokens > 768) }
    }
}
