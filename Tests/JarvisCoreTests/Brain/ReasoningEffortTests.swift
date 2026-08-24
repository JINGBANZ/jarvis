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

    @Test func defaultIsLow() {
        #expect(Defaults.Brain.effort == .low)
    }

    /// The combined cap scales with effort and never sits at the old flat 768 that starved high-effort
    /// reasoning (the truncation bug). `high` clears OpenAI's recommended ≥25k reserve.
    @Test func maxOutputTokensScalesWithEffort() {
        #expect(ReasoningEffort.none.maxOutputTokens < ReasoningEffort.low.maxOutputTokens)
        #expect(ReasoningEffort.low.maxOutputTokens < ReasoningEffort.medium.maxOutputTokens)
        #expect(ReasoningEffort.medium.maxOutputTokens < ReasoningEffort.high.maxOutputTokens)
        #expect(ReasoningEffort.high.maxOutputTokens >= 25_000)
        for e in ReasoningEffort.allCases { #expect(e.maxOutputTokens > 768) }
    }
}
