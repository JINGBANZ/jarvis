import Testing
@testable import JarvisCore

/// The one builder of the coaching system prompt, which `CoachAttemptRunner` calls for every request.
@Suite struct CoachSystemPromptTests {
    private let withCatalog = CoachCapabilities(
        tools: coachTools(detailEnabled: false) + [ToolDef(
            name: "search_prep_notes",
            description: searchPrepNotesTool.description,
            parametersJSON: "{}",
            guidance: searchPrepNotesTool.guidance,
            deferLoading: true)])

    /// Hot-tool guidance is appended in declared order. A session with nothing to load therefore
    /// sends the base prompt followed by capture evidence rules and the tip style.
    @Test func bareBuilderIsTheBasePromptPlusTipStyle() {
        #expect(JarvisPrompts.Coach.system(capabilities: .default)
            == [JarvisPrompts.Coach.system, captureScreenTool.guidance,
                speakTool(detailEnabled: false).guidance]
                .joined(separator: "\n\n"))
    }

    /// The detail rules travel with `speak`, so a session without the box never reads about a field
    /// it cannot send.
    @Test func theDetailSectionAppearsOnlyWhenTheBoxIsOn() {
        let without = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: false, detailEnabled: false))
        #expect(!without.contains("# Detail"))
        #expect(!without.contains("detail"))

        let with = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: false, detailEnabled: true))
        #expect(with.contains("# Detail"))
        #expect(with.contains("The lines are the coaching."))
        #expect(with.contains("# Tip style"))
    }

    /// Domain rules live in the skills that own them, never in the prompt every session pays for.
    @Test func theCoreCarriesNoCodeOrDiagramRules() {
        let prompt = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true, skills: skills, detailEnabled: true))
        #expect(!prompt.contains("mermaid"))
        #expect(!prompt.contains("codeSnippet"))
        #expect(!prompt.contains("highlightedLines"))
        #expect(!prompt.contains("# Code accompanies"))
        #expect(!prompt.contains("# Explain when understanding is missing"))
    }

    /// A prompt names a loader only when the session has something to load. The action policy's
    /// numbering is fixed either way: loading is its own section, not an item that renumbers five.
    @Test func theLoadingSectionAndCatalogAppearOnlyWithADeferredTool() {
        let bare = JarvisPrompts.Coach.system(capabilities: .default)
        #expect(!bare.contains("load_tool"))
        #expect(!bare.contains("# Loading"))
        #expect(!bare.contains("# Tools you can load"))
        #expect(bare.contains("1. Direct address"))
        #expect(bare.contains("6. \"me\" is stuck"))

        let offered = JarvisPrompts.Coach.system(capabilities: withCatalog)
        #expect(offered.contains("# Loading"))
        #expect(offered.contains("1. Direct address"))
        #expect(offered.contains("6. \"me\" is stuck"))
    }

    /// A deferred tool contributes one catalog line, never its guidance: that arrives as the
    /// `load_tool` result, so the prompt cannot describe how to use a tool the model cannot call.
    @Test func aDeferredToolIsCatalogedButNotExplained() {
        let offered = JarvisPrompts.Coach.system(capabilities: withCatalog)
        #expect(offered.contains(
            "- search_prep_notes: \(searchPrepNotesTool.description)"))
        #expect(!offered.contains("# Prep material"))
    }

    /// Base prompt, then per-tool guidance, then the tools catalog, then the skills catalog: the
    /// layout every site sends.
    @Test func theCatalogsFollowTheToolGuidanceInOrder() throws {
        let prompt = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true, skills: skills))
        let loading = try #require(prompt.range(of: "# Loading"))
        let policy = try #require(prompt.range(of: "# Action policy"))
        let tipStyle = try #require(prompt.range(of: "# Tip style"))
        let tools = try #require(prompt.range(of: "# Tools you can load"))
        let skillsBlock = try #require(prompt.range(of: "# Skills you can load"))
        #expect(loading.lowerBound < policy.lowerBound)
        #expect(policy.lowerBound < tipStyle.lowerBound)
        #expect(tipStyle.lowerBound < tools.lowerBound)
        #expect(tools.lowerBound < skillsBlock.lowerBound)
    }

    private let skills = [
        Skill(name: "behavioral", description: "Use when the question is behavioral.", body: "STAR."),
        Skill(name: "system-design", description: "Use when the question is a system design.", body: "Stages."),
    ]

    /// One line per switched-on skill, its own description verbatim — and never its body, which
    /// arrives as the `load_skill` result.
    @Test func aSkillIsCatalogedButNotExplained() {
        let prompt = JarvisPrompts.Coach.system(
            capabilities: CoachCapabilities.compose(
                disabledTools: [], prepSourcesConfigured: false, skills: skills))

        #expect(prompt.contains("# Skills you can load"))
        #expect(prompt.contains("- behavioral: Use when the question is behavioral."))
        #expect(prompt.contains("- system-design: Use when the question is a system design."))
        #expect(!prompt.contains("STAR."))
    }

    /// The loading section names the loaders the session actually has, and nothing else.
    @Test func theLoadingSectionNamesOnlyTheLoadersPresent() {
        let both = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true, skills: skills))
        #expect(both.contains("a skill listed under \"Skills you can load\" with load_skill"))
        #expect(both.contains("a tool listed under \"Tools you can load\" with load_tool"))

        let skillsOnly = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: false, skills: skills))
        #expect(skillsOnly.contains("# Loading"))
        #expect(skillsOnly.contains("with load_skill"))
        #expect(!skillsOnly.contains("load_tool"))
        #expect(!skillsOnly.contains("# Tools you can load"))

        let toolsOnly = JarvisPrompts.Coach.system(capabilities: withCatalog)
        #expect(!toolsOnly.contains("load_skill"))
        #expect(!toolsOnly.contains("# Skills you can load"))
        #expect(toolsOnly.contains("with load_tool"))
    }

    /// A coaching shortcut may load, and only the response at its cap is forced to `speak`. The
    /// loading section's last sentence is what describes that one response.
    @Test func theLoadingSectionStillDefersToAForcedSpeak() {
        let prompt = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true, skills: skills))
        #expect(prompt.contains(
            "When the turn says you must call speak, skip loading and speak with what you have."))
    }

    /// With every skill switched off and nothing to load, the session is back to the bare prompt —
    /// the successor of the old "no format selected ⇒ base prompt" invariant.
    @Test func everythingSwitchedOffIsTheBarePrompt() {
        #expect(JarvisPrompts.Coach.system(
            capabilities: CoachCapabilities.compose(
                disabledTools: ["search_prep_notes"],
                disabledSkills: ["behavioral", "system-design"],
                prepSourcesConfigured: true, skills: skills))
            == JarvisPrompts.Coach.system(capabilities: .default))
    }
}
