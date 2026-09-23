import Testing
@testable import JarvisCore

@Suite struct CoachSystemPromptTests {
    private let withCatalog = CoachCapabilities(
        tools: coachTools,
        deferredTools: [ToolDef(
            name: "search_prep_notes",
            description: searchPrepNotesTool.description,
            parametersJSON: "{}",
            guidance: searchPrepNotesTool.guidance,
            deferLoading: true)])

    @Test func bareBuilderIsTheBasePromptPlusCoreToolGuidance() {
        #expect(JarvisPrompts.Coach.system(capabilities: .default)
            == [JarvisPrompts.Coach.system, captureScreenTool.guidance,
                speakTool.guidance]
                .joined(separator: "\n\n"))
    }

    @Test func theDetailSectionIsAlwaysPresent() {
        let with = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: false))
        #expect(with.contains("# Detail"))
        #expect(with.contains("The lines are the coaching."))
        #expect(with.contains("# Tip style"))
    }

    @Test func theCoreCarriesNoCodeOrDiagramRules() {
        let prompt = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true, skills: skills))
        #expect(!prompt.contains("mermaid"))
        #expect(!prompt.contains("codeSnippet"))
        #expect(!prompt.contains("highlightedLines"))
        #expect(!prompt.contains("# Code accompanies"))
        #expect(!prompt.contains("# Explain when understanding is missing"))
    }

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

    @Test func aDeferredToolIsCatalogedButNotExplained() {
        let offered = JarvisPrompts.Coach.system(capabilities: withCatalog)
        #expect(offered.contains(
            "- search_prep_notes: \(searchPrepNotesTool.description)"))
        #expect(!offered.contains("# Prep material"))
    }

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

    @Test func aSkillIsCatalogedButNotExplained() {
        let prompt = JarvisPrompts.Coach.system(
            capabilities: CoachCapabilities.compose(
                disabledTools: [], prepSourcesConfigured: false, skills: skills))

        #expect(prompt.contains("# Skills you can load"))
        #expect(prompt.contains("- behavioral: Use when the question is behavioral."))
        #expect(prompt.contains("- system-design: Use when the question is a system design."))
        #expect(!prompt.contains("STAR."))
    }

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
        // Speak's own guidance legitimately says "skill" elsewhere, so check the leaking
        // skill-reassessment sentences specifically rather than the word "skill" anywhere.
        #expect(!toolsOnly.contains("finish skill selection"))
        #expect(!toolsOnly.contains("Load each additional applicable skill"))
    }

    @Test func theLoadingSectionStillDefersToAForcedSpeak() {
        let prompt = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true, skills: skills))
        #expect(prompt.contains(
            "Only when speak is the sole permitted tool, speak with what you have."))
    }

    @Test func everythingSwitchedOffIsTheBarePrompt() {
        #expect(JarvisPrompts.Coach.system(
            capabilities: CoachCapabilities.compose(
                disabledTools: ["search_prep_notes"],
                disabledSkills: ["behavioral", "system-design"],
                prepSourcesConfigured: true, skills: skills))
            == JarvisPrompts.Coach.system(capabilities: .default))
    }
}
