import Testing
@testable import JarvisCore

/// The one builder every assembly site calls: `CoachAttemptRunner` per turn, and `BrainComposition`
/// once at Start for a CLI provider whose instructions are fixed after construction.
@Suite struct CoachSystemPromptTests {
    @Test func bareBuilderIsTheBasePrompt() {
        #expect(JarvisPrompts.Coach.system(prepMaterial: false, formatAddendum: "")
            == JarvisPrompts.Coach.system)
    }

    @Test func prepMaterialGuidanceIsDescribedOnlyWhenOffered() {
        let offered = JarvisPrompts.Coach.system(prepMaterial: true, formatAddendum: "")
        let withheld = JarvisPrompts.Coach.system(prepMaterial: false, formatAddendum: "")
        #expect(offered.hasPrefix(JarvisPrompts.Coach.system))
        #expect(offered.contains("search_prep_notes"))
        #expect(!withheld.contains("search_prep_notes"))
    }

    /// Base prompt, then prep guidance, then format guidance: the layout every site sends.
    @Test func formatAddendumIsAppendedLast() {
        let format = "\n\n# Interview format\nSystem design."
        let prompt = JarvisPrompts.Coach.system(prepMaterial: true, formatAddendum: format)
        #expect(prompt.hasSuffix(format))
        guard let prep = prompt.range(of: "search_prep_notes"),
              let formatRange = prompt.range(of: "# Interview format") else {
            Issue.record("expected both the prep and format sections in the prompt")
            return
        }
        #expect(prep.lowerBound < formatRange.lowerBound)
    }
}
