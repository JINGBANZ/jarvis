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
        #expect(ReasoningEffort.default == .low)
    }
}
