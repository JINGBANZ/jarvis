import Testing
@testable import JarvisCore

/// Skill cards title each skill from its folder name, so the rule is pinned here.
@Suite struct SkillDisplayTitleTests {
    private func skill(_ name: String) -> Skill {
        Skill(name: name, description: "d", body: "b")
    }

    @Test func kebabCaseReadsAsSentenceCase() {
        #expect(skill("system-design").displayTitle == "System design")
    }

    @Test func aSingleWordIsCapitalized() {
        #expect(skill("behavioral").displayTitle == "Behavioral")
    }

    @Test func anInitialismStaysUpperCase() {
        #expect(skill("coding-with-ai").displayTitle == "Coding with AI")
    }

    @Test func everyBundledSkillHasATitle() {
        let skills = SkillCatalog.bundled()
        #expect(!skills.isEmpty)
        for skill in skills {
            #expect(!skill.displayTitle.isEmpty)
        }
    }
}
