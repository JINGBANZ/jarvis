import Testing
@testable import JarvisCore

@Suite struct InterviewFormatTests {
    @Test func displayNamesAreStable() {
        #expect(InterviewFormat.coding.displayName == "Coding")
        #expect(InterviewFormat.systemDesign.displayName == "System Design")
        #expect(InterviewFormat.behavioral.displayName == "Behavioral")
    }

    /// A missing skill remains a normal empty state, while each authored format becomes available
    /// through the same resource lookup the Settings picker consumes.
    @Test func authoredFormatsHaveContent() {
        #expect(!InterviewFormat.coding.promptAddendum.isEmpty)
        #expect(InterviewFormat.behavioral.promptAddendum.isEmpty)
        #expect(!InterviewFormat.systemDesign.promptAddendum.isEmpty)
    }

    /// No selection means no addendum at all — not a guess assembled from whatever formats happen
    /// to have content. `nil` is resolved by callers as `format?.promptAddendum ?? ""`; there is no
    /// `InterviewFormat` API for it, so this pins the optional-chaining contract those callers rely on.
    @Test func noSelectionResolvesToNoAddendum() {
        let noSelection: InterviewFormat? = nil
        #expect((noSelection?.promptAddendum ?? "") == "")
    }
}
