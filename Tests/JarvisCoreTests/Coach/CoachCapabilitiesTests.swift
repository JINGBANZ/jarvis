import Foundation
import Testing
@testable import JarvisCore

/// The one value the app's brain composition and the coach loop both read, so the schemas a
/// local-agent process is warmed with are the schemas the loop later sends (#273).
@Suite struct CoachCapabilitiesTests {
    /// The loader sits between the always-on actions and the catalog, and exists only while there
    /// is something left to load.
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

    /// Skills sit behind their own loader, sorted by name, and never become callable tools.
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

    /// A switched-off skill is not in the catalog and cannot be loaded; switching every one off
    /// takes the loader with them.
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

    /// A schema-enforcing provider cannot emit a name that is not in the catalog at all.
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

    /// Jarvis cannot start without screen capture, and a turn cannot end without speak or stay
    /// silent — so a hand-edited preference naming one of them changes nothing.
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

    /// What the model may call right now: every hot tool, plus whatever it has already loaded.
    @Test func callableGrowsOnlyByLoading() {
        let deferred = ToolDef(name: "later", description: "d", parametersJSON: "{}",
                               deferLoading: true)
        let capabilities = CoachCapabilities(tools: coachTools + [deferred])

        #expect(capabilities.callable(loaded: []).map(\.name)
            == ["capture_screen", "speak", "stay_silent"])
        // The loader drops out once nothing is left to load: offering it then invites a call that
        // can only be refused, and each one spends an iteration of the bounded tool loop.
        #expect(capabilities.callable(loaded: ["later"]).map(\.name)
            == ["capture_screen", "speak", "stay_silent", "later"])
        #expect(capabilities.catalogNames == ["later"])
        #expect(capabilities.tool(named: "later") == deferred)
        #expect(capabilities.tool(named: "nope") == nil)
    }

    /// A loader exists only while something remains for it to load, whether that is because the
    /// session composed no catalog or because the model has since loaded all of it. Each loader
    /// answers for its own catalog: loading every skill must not withdraw `load_tool`, or the other
    /// way round.
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
        // Both stay in `tools`, so a stale call is answered rather than refused as unknown.
        #expect(capabilities.tool(named: CoachCapabilities.loadToolName) != nil)
        #expect(capabilities.tool(named: CoachCapabilities.loadSkillName) != nil)
    }
}
