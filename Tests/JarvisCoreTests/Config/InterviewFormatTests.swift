import Testing
@testable import JarvisCore

@Suite struct InterviewFormatTests {
    @Test func displayNamesAreStable() {
        #expect(InterviewFormat.coding.displayName == "Coding")
        #expect(InterviewFormat.systemDesign.displayName == "System Design")
        #expect(InterviewFormat.behavioral.displayName == "Behavioral")
    }

    /// Coding and behavioral are already reported as working well, so they stay empty rather than
    /// getting new prompt guidance nobody asked for — system design is the one reported problem.
    @Test func onlySystemDesignHasContentToday() {
        #expect(InterviewFormat.coding.promptAddendum.isEmpty)
        #expect(InterviewFormat.behavioral.promptAddendum.isEmpty)
        #expect(!InterviewFormat.systemDesign.promptAddendum.isEmpty)
        #expect(InterviewFormat.systemDesign.promptAddendum.contains("functional requirements"))
        #expect(InterviewFormat.systemDesign.promptAddendum.contains("API"))
    }

    /// No selection means no addendum at all — not a guess assembled from whatever formats happen
    /// to have content. `nil` is resolved by callers as `format?.promptAddendum ?? ""`; there is no
    /// `InterviewFormat` API for it, so this pins the optional-chaining contract those callers rely on.
    @Test func noSelectionResolvesToNoAddendum() {
        let noSelection: InterviewFormat? = nil
        #expect((noSelection?.promptAddendum ?? "") == "")
    }
}
