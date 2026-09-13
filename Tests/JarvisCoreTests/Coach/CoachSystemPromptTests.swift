import Testing
@testable import JarvisCore

/// The one builder every assembly site calls: `CoachAttemptRunner` per turn, and `BrainComposition`
/// once at Start for a CLI provider whose instructions are fixed after construction.
@Suite struct CoachSystemPromptTests {
    private let withCatalog = CoachCapabilities(
        tools: coachTools + [ToolDef(
            name: "search_prep_notes",
            description: JarvisPrompts.Coach.ToolDescription.searchPrepNotes,
            parametersJSON: "{}",
            guidance: JarvisPrompts.Coach.ToolGuidance.searchPrepNotes,
            deferLoading: true)])

    /// The tip style moved onto `speak`, and `speak` is always offered, so a session with nothing
    /// to load still sends exactly the prompt it sent before the move.
    @Test func bareBuilderIsTheBasePromptPlusTipStyle() {
        #expect(JarvisPrompts.Coach.system(
            capabilities: .default, formatAddendum: "", explanationsEnabled: false)
            == JarvisPrompts.Coach.system + "\n\n" + JarvisPrompts.Coach.ToolGuidance.speak)
    }

    /// A prompt names a loader only when the session has something to load, and renumbers the rest
    /// of the action policy around it.
    @Test func theLoadRuleAndCatalogAppearOnlyWithADeferredTool() {
        let bare = JarvisPrompts.Coach.system(
            capabilities: .default, formatAddendum: "", explanationsEnabled: false)
        #expect(!bare.contains("load_tool"))
        #expect(!bare.contains("# Tools you can load"))
        #expect(bare.contains("1. Direct address"))
        #expect(bare.contains("6. \"me\" is stuck"))

        let offered = JarvisPrompts.Coach.system(
            capabilities: withCatalog, formatAddendum: "", explanationsEnabled: false)
        #expect(offered.contains("1. Load what this turn needs"))
        #expect(offered.contains("2. Direct address"))
        #expect(offered.contains("7. \"me\" is stuck"))
        #expect(offered.contains("Load before you capture."))
    }

    /// A deferred tool contributes one catalog line, never its guidance: that arrives as the
    /// `load_tool` result, so the prompt cannot describe how to use a tool the model cannot call.
    @Test func aDeferredToolIsCatalogedButNotExplained() {
        let offered = JarvisPrompts.Coach.system(
            capabilities: withCatalog, formatAddendum: "", explanationsEnabled: false)
        #expect(offered.contains(
            "- search_prep_notes: \(JarvisPrompts.Coach.ToolDescription.searchPrepNotes)"))
        #expect(!offered.contains("# Prep material"))
    }

    /// Base prompt, then per-tool guidance, then the catalog, then format guidance: the layout
    /// every site sends.
    @Test func formatAddendumIsAppendedLast() {
        let format = "\n\n# Interview format\nSystem design."
        let prompt = JarvisPrompts.Coach.system(capabilities: withCatalog, formatAddendum: format)
        #expect(prompt.hasSuffix(format))
        guard let tipStyle = prompt.range(of: "# Tip style"),
              let catalog = prompt.range(of: "# Tools you can load"),
              let formatRange = prompt.range(of: "# Interview format") else {
            Issue.record("expected the tip style, catalog and format sections in the prompt")
            return
        }
        #expect(tipStyle.lowerBound < catalog.lowerBound)
        #expect(catalog.lowerBound < formatRange.lowerBound)
    }
}
