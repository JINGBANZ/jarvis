import Foundation
import Testing
@testable import JarvisCore

/// The bundled skills and the reader that turns them into catalog entries. A skill's description is
/// all the model sees before deciding to load it, so the format's rules are pinned here.
@Suite struct SkillCatalogTests {
    private let valid = """
        ---
        name: behavioral
        description: Coaching for behavioral questions ("tell me about a time...").
        ---
        # Behavioral questions

        When the current question is behavioral, organize the answer as STAR.
        """

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
    ])
    func aMalformedFileIsRejected(text: String, expected: SkillParseError) {
        #expect(throws: expected) { try SkillCatalog.parse(text, folderName: "behavioral") }
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

    /// The folder is the address the model loads by, so a file that names itself something else is
    /// rejected rather than silently answering to two names.
    @Test func aNameThatIsNotItsFolderIsRejected() {
        #expect(throws: SkillParseError.nameDoesNotMatchFolder(
            name: "behavioral", folder: "system-design")) {
            try SkillCatalog.parse(valid, folderName: "system-design")
        }
    }

    /// Every skill this build ships is loadable, and its body is the guidance alone — the reader
    /// must not hand the model back its own frontmatter.
    @Test func everyBundledSkillParsesAndCarriesGuidance() throws {
        let skills = SkillCatalog.bundled()

        #expect(skills.map(\.name) == ["behavioral", "coding", "system-design"])
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

    /// A build that ships no readable skill is a generic coach, not a broken one: no loader, no
    /// catalog block, and a prompt that never names either.
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
