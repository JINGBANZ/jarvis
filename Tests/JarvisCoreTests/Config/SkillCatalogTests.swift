import Foundation
import Testing
@testable import JarvisCore

@Suite struct SkillCatalogTests {
    private let valid = """
        ---
        name: behavioral
        description: Coaching for behavioral questions ("tell me about a time...").
        ---
        # Behavioral questions

        When the current question is behavioral, organize the answer as STAR.
        """

    @Test func discoversParentAndNestedChildSkills() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ["coding/SKILL.md", "coding/coding-with-ai/SKILL.md", "behavioral/SKILL.md"]
        for path in paths + ["coding/notes.md", ".hidden/SKILL.md"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "fixture".write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("coding/loop"), withDestinationURL: root)
        let found = SkillCatalog.skillFiles(in: root).map {
            $0.resolvingSymlinksInPath().path
        }
        let expected = paths.map { root.appendingPathComponent($0).resolvingSymlinksInPath().path }
        #expect(found == expected.sorted())
    }

    @Test func aValidFileParsesIntoNameDescriptionAndBody() throws {
        let skill = try SkillCatalog.parse(valid, folderName: "behavioral")

        #expect(skill.name == "behavioral")
        #expect(skill.description
            == #"Coaching for behavioral questions ("tell me about a time...")."#)
        #expect(skill.body == """
            # Behavioral questions

            When the current question is behavioral, organize the answer as STAR.
            """)
    }

    @Test func quotedValuesLoseTheirQuotesAndUnknownKeysAreIgnored() throws {
        let skill = try SkillCatalog.parse("""
            ---
            name: "system-design"
            license: 'MIT'
            description: 'Coaching for system-design questions.'
            ---
            Body.
            """, folderName: "system-design")

        #expect(skill.name == "system-design")
        #expect(skill.description == "Coaching for system-design questions.")
        #expect(skill.body == "Body.")
    }

    @Test(arguments: [
        ("no frontmatter at all", SkillParseError.missingFrontmatter),
        ("---\nname: behavioral\n", .unterminatedFrontmatter),
        ("---\ndescription: d\n---\nBody.", .missingName),
        ("---\nname: behavioral\n---\nBody.", .missingDescription),
        ("---\nname: Behavioral\ndescription: d\n---\nBody.", .invalidName("Behavioral")),
        ("---\nname: behavioral-\ndescription: d\n---\nBody.", .invalidName("behavioral-")),
        ("---\nname: behavioral\ndescription: d\ncontinued on a second line\n---\nBody.",
         .malformedFrontmatterLine("continued on a second line")),
        ("---\nname: behavioral\ndescription: d\n---\n\n  \n", .missingBody),
    ])
    func aMalformedFileIsRejected(text: String, expected: SkillParseError) {
        #expect(throws: expected) { try SkillCatalog.parse(text, folderName: "behavioral") }
    }

    /// `CharacterSet.whitespaces` excludes `\r`, so an unnormalized reader rejects the `---` fence.
    @Test func crlfLineEndingsParseTheSameAsUnixOnes() throws {
        let skill = try SkillCatalog.parse(
            valid.replacingOccurrences(of: "\n", with: "\r\n"), folderName: "behavioral")

        #expect(skill.name == "behavioral")
        #expect(skill.description
            == #"Coaching for behavioral questions ("tell me about a time...")."#)
        #expect(skill.body == """
            # Behavioral questions

            When the current question is behavioral, organize the answer as STAR.
            """)
    }

    @Test func aNameLongerThanSixtyFourCharactersIsRejected() {
        let name = String(repeating: "a", count: 65)
        #expect(throws: SkillParseError.invalidName(name)) {
            try SkillCatalog.parse("---\nname: \(name)\ndescription: d\n---\nBody.",
                                   folderName: name)
        }
    }

    @Test func aDescriptionLongerThanTheLimitIsRejected() {
        let long = String(repeating: "d", count: 1025)
        #expect(throws: SkillParseError.descriptionTooLong(1025)) {
            try SkillCatalog.parse("---\nname: behavioral\ndescription: \(long)\n---\nBody.",
                                   folderName: "behavioral")
        }
    }

    @Test func aNameThatIsNotItsFolderIsRejected() {
        #expect(throws: SkillParseError.nameDoesNotMatchFolder(
            name: "behavioral", folder: "system-design")) {
            try SkillCatalog.parse(valid, folderName: "system-design")
        }
    }

    @Test func everyBundledSkillParsesAndCarriesGuidance() throws {
        let skills = SkillCatalog.bundled()

        #expect(skills.map(\.name) == ["behavioral", "coding", "coding-with-ai", "system-design"])
        for skill in skills {
            #expect(!skill.description.isEmpty)
            #expect(!skill.body.hasPrefix("---"))
            #expect(!skill.body.contains("description:"))
            #expect(skill.body.count > 200)
        }
        let behavioral = try #require(skills.first { $0.name == "behavioral" })
        #expect(behavioral.body.contains("STAR"))
        #expect(behavioral.body.contains("load_tool"))
        let design = try #require(skills.first { $0.name == "system-design" })
        #expect(design.body.contains("mermaid"))
        #expect(skills.first { $0.name == "coding" }?.body.contains("invariant") == true)
    }

    @Test func aiCodingUsesTheExistingOptionalSkillCatalog() throws {
        let skills = SkillCatalog.bundled()
        let ai = try #require(skills.first { $0.name == "coding-with-ai" })
        let enabled = CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: false, skills: skills)
        #expect(enabled.skill(named: ai.name) == ai)
        #expect(enabled.tool(named: "load_skill")?.parametersJSON.contains(ai.name) == true)
        let prompt = JarvisPrompts.Coach.system(capabilities: enabled)
        #expect(prompt.contains("- \(ai.name): \(ai.description)"))
        #expect(!prompt.contains(ai.body))

        let disabled = CoachCapabilities.compose(
            disabledTools: [], disabledSkills: [ai.name],
            prepSourcesConfigured: false, skills: skills)
        #expect(disabled.skill(named: ai.name) == nil)
        #expect(disabled.skill(named: "coding") != nil)
        #expect(disabled.tool(named: "load_skill")?.parametersJSON.contains(ai.name) == false)
        #expect(!JarvisPrompts.Coach.system(capabilities: disabled).contains(ai.name))
    }

    @Test func noSkillsMeansNoLoaderAndNoCatalog() {
        let capabilities = CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: false, skills: [])
        let prompt = JarvisPrompts.Coach.system(capabilities: capabilities)

        #expect(capabilities.skills.isEmpty)
        #expect(capabilities.tool(named: CoachCapabilities.loadSkillName) == nil)
        #expect(!prompt.contains("load_skill"))
        #expect(!prompt.contains("# Skills you can load"))
    }
}
