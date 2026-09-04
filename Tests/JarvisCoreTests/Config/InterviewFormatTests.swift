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
        #expect(InterviewFormat.coding.promptAddendum.contains("# Interview format: coding"))
        #expect(InterviewFormat.behavioral.promptAddendum.isEmpty)
        #expect(InterviewFormat.systemDesign.promptAddendum.contains("API"))
    }

    @Test func noSelectionResolvesToAutomaticGuidance() {
        let addendum = InterviewFormat.resolvedPromptAddendum(for: nil)

        #expect(addendum.contains("Choose coaching behavior"))
        #expect(addendum.contains("For a coding task"))
        #expect(addendum.contains("functional requirements"))
    }

    @Test func explicitSelectionDoesNotIncludeAutomaticRouting() {
        let addendum = InterviewFormat.resolvedPromptAddendum(for: .coding)

        #expect(addendum.contains("tokenizer"))
        #expect(!addendum.contains("functional requirements"))
        #expect(!addendum.contains("Choose coaching behavior"))
    }
}
