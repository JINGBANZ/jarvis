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
    /// to load still sends exactly the base prompt plus that guidance.
    @Test func bareBuilderIsTheBasePromptPlusTipStyle() {
        #expect(JarvisPrompts.Coach.system(capabilities: .default, explanationsEnabled: false)
            == JarvisPrompts.Coach.system + "\n\n" + JarvisPrompts.Coach.ToolGuidance.speak)
    }

    /// A prompt names a loader only when the session has something to load, and renumbers the rest
    /// of the action policy around it.
    @Test func theLoadRuleAndCatalogAppearOnlyWithADeferredTool() {
        let bare = JarvisPrompts.Coach.system(capabilities: .default, explanationsEnabled: false)
        #expect(!bare.contains("load_tool"))
        #expect(!bare.contains("# Tools you can load"))
        #expect(bare.contains("1. Direct address"))
        #expect(bare.contains("6. \"me\" is stuck"))

        let offered = JarvisPrompts.Coach.system(
            capabilities: withCatalog, explanationsEnabled: false)
        #expect(offered.contains("1. Load what this turn needs"))
        #expect(offered.contains("2. Direct address"))
        #expect(offered.contains("7. \"me\" is stuck"))
        #expect(offered.contains("Load before you capture."))
    }

    /// A deferred tool contributes one catalog line, never its guidance: that arrives as the
    /// `load_tool` result, so the prompt cannot describe how to use a tool the model cannot call.
    @Test func aDeferredToolIsCatalogedButNotExplained() {
        let offered = JarvisPrompts.Coach.system(
            capabilities: withCatalog, explanationsEnabled: false)
        #expect(offered.contains(
            "- search_prep_notes: \(JarvisPrompts.Coach.ToolDescription.searchPrepNotes)"))
        #expect(!offered.contains("# Prep material"))
    }

    /// Base prompt, then per-tool guidance, then the catalog: the layout every site sends.
    @Test func theCatalogFollowsTheToolGuidance() throws {
        let prompt = JarvisPrompts.Coach.system(capabilities: withCatalog)
        let tipStyle = try #require(prompt.range(of: "# Tip style"))
        let catalog = try #require(prompt.range(of: "# Tools you can load"))
        #expect(tipStyle.lowerBound < catalog.lowerBound)
    }
}
