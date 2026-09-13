import Testing
@testable import JarvisCore

/// The one builder every assembly site calls: `CoachAttemptRunner` per turn, and `BrainComposition`
/// once at Start for a CLI provider whose instructions are fixed after construction.
@Suite struct CoachSystemPromptTests {
    private let withCatalog = CoachCapabilities(
        tools: coachTools + [ToolDef(
            name: "search_prep_notes",
            description: searchPrepNotesTool.description,
            parametersJSON: "{}",
            guidance: searchPrepNotesTool.guidance,
            deferLoading: true)])

    /// The tip style moved onto `speak`, and `speak` is always offered, so a session with nothing
    /// to load still sends exactly the base prompt plus that guidance.
    @Test func bareBuilderIsTheBasePromptPlusTipStyle() {
        #expect(JarvisPrompts.Coach.system(capabilities: .default, explanationsEnabled: false)
            == JarvisPrompts.Coach.system + "\n\n" + speakTool.guidance)
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
            "- search_prep_notes: \(searchPrepNotesTool.description)"))
        #expect(!offered.contains("# Prep material"))
    }

    /// Base prompt, then per-tool guidance, then the tools catalog, then the skills catalog: the
    /// layout every site sends.
    @Test func theCatalogsFollowTheToolGuidanceInOrder() throws {
        let prompt = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true, skills: skills))
        let tipStyle = try #require(prompt.range(of: "# Tip style"))
        let tools = try #require(prompt.range(of: "# Tools you can load"))
        let skillsBlock = try #require(prompt.range(of: "# Skills you can load"))
        #expect(tipStyle.lowerBound < tools.lowerBound)
        #expect(tools.lowerBound < skillsBlock.lowerBound)
    }

    private let skills = [
        Skill(name: "behavioral", description: "Coaching for behavioral questions.", body: "STAR."),
        Skill(name: "system-design", description: "Coaching for design questions.", body: "Stages."),
    ]

    /// One line per switched-on skill, its own description verbatim — and never its body, which
    /// arrives as the `load_skill` result.
    @Test func aSkillIsCatalogedButNotExplained() {
        let prompt = JarvisPrompts.Coach.system(
            capabilities: CoachCapabilities.compose(
                disabledTools: [], prepSourcesConfigured: false, skills: skills),
            explanationsEnabled: false)

        #expect(prompt.contains("# Skills you can load"))
        #expect(prompt.contains("- behavioral: Coaching for behavioral questions."))
        #expect(prompt.contains("- system-design: Coaching for design questions."))
        #expect(!prompt.contains("STAR."))
    }

    /// The rule names the loaders the session actually has, and nothing else.
    @Test func theLoadRuleNamesOnlyTheLoadersPresent() {
        let both = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true, skills: skills))
        #expect(both.contains("call load_skill with its name"))
        #expect(both.contains("call load_tool with its name"))
        #expect(both.contains("If a skill or tool for this question is not loaded yet"))

        let skillsOnly = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: false, skills: skills))
        #expect(skillsOnly.contains("1. Load what this turn needs"))
        #expect(skillsOnly.contains("call load_skill with its name"))
        #expect(!skillsOnly.contains("load_tool"))
        #expect(!skillsOnly.contains("# Tools you can load"))
        #expect(skillsOnly.contains("If a skill for this question is not loaded yet"))

        let toolsOnly = JarvisPrompts.Coach.system(capabilities: withCatalog)
        #expect(!toolsOnly.contains("load_skill"))
        #expect(!toolsOnly.contains("# Skills you can load"))
        #expect(toolsOnly.contains("If a tool for this question is not loaded yet"))
    }

    /// With every skill switched off and nothing to load, the session is back to the bare prompt —
    /// the successor of the old "no format selected ⇒ base prompt" invariant.
    @Test func everythingSwitchedOffIsTheBarePrompt() {
        #expect(JarvisPrompts.Coach.system(
            capabilities: CoachCapabilities.compose(
                disabledTools: ["search_prep_notes"],
                disabledSkills: ["behavioral", "system-design"],
                prepSourcesConfigured: true, skills: skills),
            explanationsEnabled: false)
            == JarvisPrompts.Coach.system(capabilities: .default, explanationsEnabled: false))
    }
}
