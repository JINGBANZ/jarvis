import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachCapabilitiesTests {
    @Test func theThreeCoachingActionsComeFirstAndAlwaysInTheSameOrder() {
        let offered = CoachCapabilities.compose(disabledTools: [], prepSourcesConfigured: true)
        #expect(offered.tools.map(\.name)
            == ["capture_screen", "speak", "stay_silent", "load_tool", "search_prep_notes"])
        #expect(offered.catalogNames == ["search_prep_notes"])
        #expect(CoachCapabilities.default.tools.map(\.name)
            == ["capture_screen", "speak", "stay_silent"])
        #expect(CoachCapabilities.default.deferredTools.isEmpty)
    }

    private let skills = [Skill(name: "system-design", description: "design questions", body: "b1"),
                          Skill(name: "behavioral", description: "STAR questions", body: "b2")]

    @Test func theSkillLoaderIsPresentOnlyWithASwitchedOnSkill() throws {
        let offered = CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true, skills: skills)
        #expect(offered.tools.map(\.name) == ["capture_screen", "speak", "stay_silent",
                                              "load_tool", "load_skill", "search_prep_notes"])
        #expect(offered.skills.map(\.name) == ["behavioral", "system-design"])

        let loader = try #require(offered.tool(named: CoachCapabilities.loadSkillName))
        let schema = try #require(JSONSerialization.jsonObject(
            with: Data(loader.parametersJSON.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let name = try #require(properties["name"] as? [String: Any])
        #expect(name["enum"] as? [String] == ["behavioral", "system-design"])
        #expect(!loader.deferLoading)

        #expect(offered.skill(named: "behavioral")?.body == "b2")
        #expect(offered.skill(named: "coding") == nil)
    }

    @Test func aSwitchedOffSkillIsNotOffered() {
        let some = CoachCapabilities.compose(
            disabledTools: [], disabledSkills: ["behavioral", "not-a-skill"],
            prepSourcesConfigured: false, skills: skills)
        #expect(some.skills.map(\.name) == ["system-design"])
        #expect(some.tool(named: CoachCapabilities.loadSkillName) != nil)

        let none = CoachCapabilities.compose(
            disabledTools: [], disabledSkills: ["behavioral", "system-design"],
            prepSourcesConfigured: false, skills: skills)
        #expect(none.skills.isEmpty)
        #expect(none.tool(named: CoachCapabilities.loadSkillName) == nil)
        #expect(none.tools.map(\.name) == ["capture_screen", "speak", "stay_silent"])
    }

    @Test func theLoaderOffersExactlyTheCatalogNames() throws {
        let loader = try #require(CoachCapabilities
            .compose(disabledTools: [], prepSourcesConfigured: true)
            .tool(named: CoachCapabilities.loadToolName))
        let schema = try #require(JSONSerialization.jsonObject(
            with: Data(loader.parametersJSON.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let name = try #require(properties["name"] as? [String: Any])

        #expect(name["enum"] as? [String] == ["search_prep_notes"])
        #expect(!loader.deferLoading)
    }

    @Test func fixedToolsIgnoreTheSwitches() {
        let capabilities = CoachCapabilities.compose(
            disabledTools: ["capture_screen", "speak", "stay_silent", "load_tool", "load_skill",
                            "not_a_tool"],
            prepSourcesConfigured: true, skills: skills)

        #expect(capabilities.tools.map(\.name) == ["capture_screen", "speak", "stay_silent",
                                                   "load_tool", "load_skill", "search_prep_notes"])
    }

    @Test func prepSearchIsPresentOnlyWhenConfiguredAndNotSwitchedOff() {
        #expect(!CoachCapabilities.compose(disabledTools: [], prepSourcesConfigured: false)
            .tools.map(\.name).contains("search_prep_notes"))
        #expect(!CoachCapabilities.compose(
            disabledTools: ["search_prep_notes"], prepSourcesConfigured: true)
            .tools.map(\.name).contains("search_prep_notes"))
    }

    @Test func callableGrowsOnlyByLoading() {
        let deferred = ToolDef(name: "later", description: "d", parametersJSON: "{}",
                               deferLoading: true)
        let capabilities = CoachCapabilities(tools: coachTools + [deferred])

        #expect(capabilities.callable(loaded: []).map(\.name)
            == ["capture_screen", "speak", "stay_silent"])
        #expect(capabilities.callable(loaded: ["later"]).map(\.name)
            == ["capture_screen", "speak", "stay_silent", "later"])
        #expect(capabilities.catalogNames == ["later"])
        #expect(capabilities.tool(named: "later") == deferred)
        #expect(capabilities.tool(named: "nope") == nil)
    }

    @Test func eachLoaderDisappearsOnceItsOwnCatalogIsLoaded() {
        let capabilities = CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true, skills: skills)
        let skillKeys = skills.map { CoachCapabilities.loadedKey(forSkill: $0.name) }

        #expect(capabilities.callable(loaded: []).map(\.name)
            == ["capture_screen", "speak", "stay_silent", "load_tool", "load_skill"])
        #expect(capabilities.callable(loaded: Set([skillKeys[0]])).map(\.name)
            == ["capture_screen", "speak", "stay_silent", "load_tool", "load_skill"])
        #expect(capabilities.callable(loaded: Set(skillKeys)).map(\.name)
            == ["capture_screen", "speak", "stay_silent", "load_tool"])
        #expect(capabilities.callable(loaded: ["search_prep_notes"]).map(\.name)
            == ["capture_screen", "speak", "stay_silent", "load_skill", "search_prep_notes"])
        #expect(capabilities.callable(loaded: Set(skillKeys + ["search_prep_notes"])).map(\.name)
            == ["capture_screen", "speak", "stay_silent", "search_prep_notes"])
        #expect(capabilities.tool(named: CoachCapabilities.loadToolName) != nil)
        #expect(capabilities.tool(named: CoachCapabilities.loadSkillName) != nil)
    }
}
