import Testing
@testable import JarvisCore

@Suite struct OverlayTextTests {
    @Test func splitsAndCapsAtThree() {
        let input = "First idea. Second thought! Third point? Fourth dropped."
        let out = splitIntoSentences(input, maxSentences: 3)
        #expect(out == ["First idea.", "Second thought!", "Third point?"])
    }

    @Test func fewerThanMaxReturnsAll() {
        let out = splitIntoSentences("Only one here.", maxSentences: 3)
        #expect(out == ["Only one here."])
    }

    @Test func trimsWhitespaceAndIgnoresEmpty() {
        let out = splitIntoSentences("  Hi.   There.  ", maxSentences: 3)
        #expect(out == ["Hi.", "There."])
    }

    @Test func noTerminatorTreatedAsOneSentence() {
        let out = splitIntoSentences("no terminator here", maxSentences: 3)
        #expect(out == ["no terminator here"])
    }
}
