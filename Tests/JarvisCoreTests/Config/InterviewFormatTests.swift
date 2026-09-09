import Testing
@testable import JarvisCore

@Suite struct InterviewFormatTests {
    @Test func displayNamesAreStable() {
        #expect(InterviewFormat.coding.displayName == "Coding")
        #expect(InterviewFormat.systemDesign.displayName == "System Design")
        #expect(InterviewFormat.behavioral.displayName == "Behavioral")
    }

    /// Missing skills remain a normal empty state, while each authored format becomes available
    /// through the same resource lookup the Settings picker consumes.
    @Test func authoredFormatsHaveExpectedContent() {
        #expect(InterviewFormat.coding.promptAddendum.contains("# Interview format: coding"))
        #expect(InterviewFormat.behavioral.promptAddendum.contains(
            "# Interview format: behavioral"))
        #expect(InterviewFormat.behavioral.promptAddendum.contains("STAR"))
        #expect(InterviewFormat.behavioral.promptAddendum.contains(
            "candidate-owned events"))
        #expect(!InterviewFormat.systemDesign.promptAddendum.isEmpty)
        #expect(InterviewFormat.systemDesign.promptAddendum.contains("functional requirements"))
        #expect(InterviewFormat.systemDesign.promptAddendum.contains("API"))
    }

    @Test func generalTechnicalIsAnExplicitAuthoredFormat() {
        #expect(InterviewFormat.generalTechnical.displayName == "General Technical")
        #expect(InterviewFormat.generalTechnical.promptAddendum.contains("# Interview format: general technical"))
        #expect(InterviewFormat.allCases.contains(.generalTechnical))
    }
}
