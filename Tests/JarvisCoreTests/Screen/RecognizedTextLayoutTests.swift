import Testing
@testable import JarvisCore

@Suite struct RecognizedTextLayoutTests {
    /// Fragment boxes are normalized, top-left origin: `row` is the line number in a 40-line page.
    private func fragment(_ text: String, row: Double, x: Double = 0.1) -> TextFragment {
        TextFragment(string: text, minX: x, minY: row * 0.025, width: 0.3, height: 0.02)
    }

    @Test func ordersTopToBottomRegardlessOfInputOrder() {
        let text = RecognizedTextLayout.orderedText([
            fragment("third", row: 3), fragment("first", row: 1), fragment("second", row: 2),
        ])
        #expect(text == "first\nsecond\nthird")
    }

    /// Fragments sharing a vertical band are one reading line, ordered left-to-right — e.g. a
    /// line number gutter next to a code line.
    @Test func joinsVerticallyOverlappingFragmentsLeftToRight() {
        let text = RecognizedTextLayout.orderedText([
            fragment("while(true){", row: 1, x: 0.2),
            fragment("16", row: 1, x: 0.05),
        ])
        #expect(text == "16   while(true){")
    }

    /// Boxes drift a little between OCR lines; a fragment clearly below the current band starts a
    /// new line even when the gap is small.
    @Test func slightVerticalDriftDoesNotMergeAdjacentRows() {
        let a = TextFragment(string: "line one", minX: 0.1, minY: 0.100, width: 0.3, height: 0.020)
        let b = TextFragment(string: "line two", minX: 0.1, minY: 0.122, width: 0.3, height: 0.020)
        #expect(RecognizedTextLayout.orderedText([a, b]) == "line one\nline two")
    }

    /// The documented PoC limit: side-by-side columns interleave line-by-line. Each fragment stays
    /// intact — this pins the CURRENT behavior so a future column-clustering fix must update it
    /// deliberately.
    @Test func sideBySideColumnsInterleaveLineByLine() {
        let text = RecognizedTextLayout.orderedText([
            fragment("problem statement", row: 1, x: 0.05),
            fragment("class Solution {", row: 1, x: 0.55),
            fragment("second sentence", row: 2, x: 0.05),
        ])
        #expect(text == "problem statement   class Solution {\nsecond sentence")
    }

    @Test func emptyInputYieldsNil() {
        #expect(RecognizedTextLayout.orderedText([]) == nil)
    }
}
