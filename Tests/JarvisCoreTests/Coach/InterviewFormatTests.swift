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

    @Test func explicitSelectionResolvesToExactlyItsOwnAddendum() {
        #expect(InterviewFormat.resolvedPromptAddendum(for: .coding) == "")
        #expect(InterviewFormat.resolvedPromptAddendum(for: .behavioral) == "")
        #expect(InterviewFormat.resolvedPromptAddendum(for: .systemDesign)
            == InterviewFormat.systemDesign.promptAddendum)
    }

    /// No selection never guesses — it includes every non-empty addendum, which today means it's
    /// indistinguishable from selecting system design explicitly, since that's the only one with
    /// content. This is expected, not a bug: see wiki/decisions.md (2026-09-01).
    @Test func automaticIncludesEveryNonEmptyAddendumWithoutGuessing() {
        #expect(InterviewFormat.resolvedPromptAddendum(for: nil)
            == InterviewFormat.systemDesign.promptAddendum)
    }
}
