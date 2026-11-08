import Testing
@testable import JarvisCore

@Suite struct CoachSystemPromptTests {
    private let withCatalog = CoachCapabilities(
        tools: coachTools,
        deferredTools: [ToolDef(
            name: "search_references",
            description: searchReferencesTool.description,
            parametersJSON: "{}",
            guidance: searchReferencesTool.guidance,
            deferLoading: true)])

    @Test func bareBuilderContainsOnlyGeneralPolicy() {
        #expect(JarvisPrompts.Coach.system(capabilities: .default) == JarvisPrompts.Coach.system)
        #expect(!JarvisPrompts.Coach.system.contains(captureScreenTool.guidance))
        #expect(!JarvisPrompts.Coach.system.contains(speakTool.guidance))
    }

    @Test func toolGuidanceLivesInDeclarations() {
        let capabilities = CoachCapabilities.compose(disabledTools: [], referencesAdmitted: false)
        let prompt = JarvisPrompts.Coach.system(capabilities: capabilities)
        #expect(!prompt.contains("Optional Markdown displayed below the hint"))
        #expect(capabilities.tool(named: "speak")?.parametersJSON.contains("Optional Markdown displayed below the hint") == true)
        #expect(capabilities.tool(named: "capture_screen")?.descriptionWithGuidance.contains("# When to capture") == true)
    }

    @Test func theCoreCarriesNoCodeOrDiagramRules() {
        let prompt = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], referencesAdmitted: true, skills: skills))
        #expect(!prompt.contains("mermaid"))
        #expect(!prompt.contains("codeSnippet"))
        #expect(!prompt.contains("highlightedLines"))
        #expect(!prompt.contains("# Code accompanies"))
        #expect(!prompt.contains("Use concise code expressions"))
        #expect(!prompt.contains("# Explain when understanding is missing"))
    }

    @Test func theLoadingSectionAndCatalogAppearOnlyWithADeferredTool() {
        let bare = JarvisPrompts.Coach.system(capabilities: .default)
        #expect(!bare.contains("load_tool"))
        #expect(!bare.contains("# Skills and tool discovery"))
        #expect(!bare.contains("# Available additional tools"))
        #expect(bare.contains("1. When \"me\" addresses Jarvis"))
        #expect(bare.contains("6. When the user appears stuck"))

        let offered = JarvisPrompts.Coach.system(capabilities: withCatalog)
        #expect(offered.contains("# Skills and tool discovery"))
        #expect(offered.contains("1. When \"me\" addresses Jarvis"))
        #expect(offered.contains("6. When the user appears stuck"))
    }

    @Test func aDeferredToolIsCatalogedButNotExplained() {
        let offered = JarvisPrompts.Coach.system(capabilities: withCatalog)
        #expect(offered.contains(
            "- search_references: \(searchReferencesTool.description)"))
        #expect(!offered.contains("# Prep material"))
    }

    @Test func theCatalogsFollowGeneralPolicyInOrder() throws {
        let prompt = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], referencesAdmitted: true, skills: skills))
        let discovery = try #require(prompt.range(of: "# Skills and tool discovery"))
        let policy = try #require(prompt.range(of: "# Response policy"))
        let tools = try #require(prompt.range(of: "# Available additional tools"))
        let skillsBlock = try #require(prompt.range(of: "# Available skills"))
        #expect(discovery.lowerBound < policy.lowerBound)
        #expect(policy.lowerBound < tools.lowerBound)
        #expect(tools.lowerBound < skillsBlock.lowerBound)
    }

    private let skills = [
        Skill(name: "behavioral", description: "Use when the question is behavioral.", body: "STAR."),
        Skill(name: "system-design", description: "Use when the question is a system design.", body: "Stages."),
    ]

    @Test func aSkillIsCatalogedButNotExplained() {
        let prompt = JarvisPrompts.Coach.system(
            capabilities: CoachCapabilities.compose(
                disabledTools: [], referencesAdmitted: false, skills: skills))

        #expect(prompt.contains("# Available skills"))
        #expect(prompt.contains("- behavioral: Use when the question is behavioral."))
        #expect(prompt.contains("- system-design: Use when the question is a system design."))
        #expect(!prompt.contains("STAR."))
    }

    @Test func discoveryNamesOnlyTheCatalogsPresent() {
        let both = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], referencesAdmitted: true, skills: skills))
        #expect(both.contains("use load_skill"))
        #expect(both.contains("Its loader and invocation tools"))
        #expect(both.contains("including after a capture"))
        let skillsOnly = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], referencesAdmitted: false, skills: skills))
        #expect(skillsOnly.contains("use load_skill"))
        #expect(!skillsOnly.contains("# Available additional tools"))
        #expect(!skillsOnly.contains("Its loader and invocation tools"))
        let toolsOnly = JarvisPrompts.Coach.system(capabilities: withCatalog)
        #expect(!toolsOnly.contains("load_skill"))
        #expect(!toolsOnly.contains("# Available skills"))
        #expect(toolsOnly.contains("Its loader and invocation tools"))
        #expect(!toolsOnly.contains("load any additional applicable skill"))
    }

    @Test func theLoadingSectionStillDefersToAForcedSpeak() {
        let prompt = JarvisPrompts.Coach.system(capabilities: CoachCapabilities.compose(
            disabledTools: [], referencesAdmitted: true, skills: skills))
        #expect(prompt.contains(
            "When only speak and/or stay_silent are permitted, finish using the evidence and guidance already"))
    }

    @Test func everythingSwitchedOffIsTheBarePrompt() {
        #expect(JarvisPrompts.Coach.system(
            capabilities: CoachCapabilities.compose(
                disabledTools: ["search_references"],
                disabledSkills: ["behavioral", "system-design"],
                referencesAdmitted: true, skills: skills))
            == JarvisPrompts.Coach.system(capabilities: .default))
    }
}
