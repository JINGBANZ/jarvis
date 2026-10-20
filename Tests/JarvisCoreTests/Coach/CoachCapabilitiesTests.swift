import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoachCapabilitiesTests {
    @Test func theThreeCoachingActionsComeFirstAndAlwaysInTheSameOrder() {
        let offered = CoachCapabilities.compose(disabledTools: [], referencesAdmitted: true)
        #expect(offered.tools.map(\.name)
            == ["capture_screen", "speak", "stay_silent", "load_tool", "call_tool"])
        #expect(offered.catalogNames == ["list_references", "search_references", "read_reference"])
        #expect(CoachCapabilities.default.tools.map(\.name)
            == ["capture_screen", "speak", "stay_silent"])
        #expect(CoachCapabilities.default.deferredTools.isEmpty)
    }

    private let skills = [Skill(name: "system-design", description: "design questions", body: "b1"),
                          Skill(name: "behavioral", description: "STAR questions", body: "b2")]

    @Test func theSkillLoaderIsPresentOnlyWithASwitchedOnSkill() throws {
        let offered = CoachCapabilities.compose(
            disabledTools: [], referencesAdmitted: true, skills: skills)
        #expect(offered.tools.map(\.name) == ["capture_screen", "speak", "stay_silent",
                                              "load_tool", "call_tool", "load_skill"])
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
            referencesAdmitted: false, skills: skills)
        #expect(some.skills.map(\.name) == ["system-design"])
        #expect(some.tool(named: CoachCapabilities.loadSkillName) != nil)

        let none = CoachCapabilities.compose(
            disabledTools: [], disabledSkills: ["behavioral", "system-design"],
            referencesAdmitted: false, skills: skills)
        #expect(none.skills.isEmpty)
        #expect(none.tool(named: CoachCapabilities.loadSkillName) == nil)
        #expect(none.tools.map(\.name) == ["capture_screen", "speak", "stay_silent"])
    }

    @Test func theLoaderOffersExactlyTheCatalogNames() throws {
        let loader = try #require(CoachCapabilities
            .compose(disabledTools: [], referencesAdmitted: true)
            .tool(named: CoachCapabilities.loadToolName))
        let schema = try #require(JSONSerialization.jsonObject(
            with: Data(loader.parametersJSON.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let name = try #require(properties["name"] as? [String: Any])

        #expect(name["enum"] as? [String] == ["list_references", "search_references", "read_reference"])
        #expect(!loader.deferLoading)
    }

    @Test func fixedToolsIgnoreTheSwitches() {
        let capabilities = CoachCapabilities.compose(
            disabledTools: ["capture_screen", "speak", "stay_silent", "load_tool", "call_tool",
                            "load_skill", "not_a_tool"],
            referencesAdmitted: true, skills: skills)

        #expect(capabilities.tools.map(\.name) == ["capture_screen", "speak", "stay_silent",
                                                   "load_tool", "call_tool", "load_skill"])
    }

    @Test func prepSearchIsPresentOnlyWhenConfiguredAndNotSwitchedOff() {
        #expect(CoachCapabilities.compose(disabledTools: [], referencesAdmitted: true)
            .catalogNames == ["list_references", "search_references", "read_reference"])
        #expect(!CoachCapabilities.compose(disabledTools: [], referencesAdmitted: false)
            .catalogNames.contains("search_references"))
        #expect(!CoachCapabilities.compose(
            disabledTools: ["search_references"], referencesAdmitted: true)
            .catalogNames.contains("search_references"))
    }

    @Test func callableNamesGrowOnlyByLoadingWhileTheListStaysFixed() {
        let later = ToolDef(name: "later", description: "d", parametersJSON: "{}", deferLoading: true)
        let capabilities = CoachCapabilities(
            tools: coachTools + [CoachCapabilities.loadTool(catalogNames: ["later"]),
                                 CoachCapabilities.callTool(catalogNames: ["later"])],
            deferredTools: [later])

        #expect(capabilities.tools.map(\.name)
            == ["capture_screen", "speak", "stay_silent", "load_tool", "call_tool"])
        #expect(capabilities.callableNames(loaded: [])
            == ["capture_screen", "speak", "stay_silent", "load_tool"])
        #expect(capabilities.callableNames(loaded: ["later"])
            == ["capture_screen", "speak", "stay_silent", "call_tool"])
        #expect(capabilities.catalogNames == ["later"])
        #expect(capabilities.tool(named: "later") == later)
        #expect(capabilities.tool(named: "nope") == nil)
    }

    @Test func eachLoaderLeavesTheCallableSetOnceItsCatalogIsLoaded() {
        let capabilities = CoachCapabilities.compose(
            disabledTools: [], referencesAdmitted: true, skills: skills)
        let skillKeys = skills.map { CoachCapabilities.loadedKey(forSkill: $0.name) }

        #expect(capabilities.tools.map(\.name)
            == ["capture_screen", "speak", "stay_silent", "load_tool", "call_tool", "load_skill"])
        #expect(capabilities.callableNames(loaded: [])
            == ["capture_screen", "speak", "stay_silent", "load_tool", "load_skill"])
        #expect(capabilities.callableNames(loaded: Set([skillKeys[0]]))
            == ["capture_screen", "speak", "stay_silent", "load_tool", "load_skill"])
        #expect(capabilities.callableNames(loaded: Set(skillKeys))
            == ["capture_screen", "speak", "stay_silent", "load_tool"])
        #expect(capabilities.callableNames(loaded: ["list_references", "search_references", "read_reference"])
            == ["capture_screen", "speak", "stay_silent", "call_tool", "load_skill"])
        #expect(capabilities.callableNames(loaded: Set(skillKeys + ["list_references", "search_references", "read_reference"]))
            == ["capture_screen", "speak", "stay_silent", "call_tool"])
    }

    @Test func skillAndToolLoadsHaveIndependentCallablePolicy() {
        let skill = Skill(name: "search_references", description: "Coaching policy", body: "Skill guidance")
        let capabilities = CoachCapabilities.compose(
            disabledTools: [], referencesAdmitted: true, skills: [skill])
        let skillLoaded = capabilities.callableNames(loaded: [CoachCapabilities.loadedKey(forSkill: skill.name)])
        #expect(!skillLoaded.contains("load_skill"))
        #expect(skillLoaded.contains("load_tool"))
        #expect(!skillLoaded.contains("call_tool"))
        let toolLoaded = capabilities.callableNames(loaded: ["list_references", "search_references", "read_reference"])
        #expect(toolLoaded.contains("load_skill"))
        #expect(!toolLoaded.contains("load_tool"))
        #expect(toolLoaded.contains("call_tool"))
    }

    @Test func callToolRoutesOnlyToTheCatalogAndTakesArgumentsAsText() throws {
        let capabilities = CoachCapabilities.compose(disabledTools: [], referencesAdmitted: true)
        let callTool = try #require(capabilities.tool(named: "call_tool"))
        #expect(callTool.parametersJSON.contains(#""enum":["list_references","search_references","read_reference"]"#))
        #expect(callTool.parametersJSON.contains(#""arguments":{"type":"string""#))
        #expect(!capabilities.tools.contains { $0.name == "search_references" })
    }

    @Test func onlyAHotToolRunsAndARejectionNamesTheSchemaToQuote() throws {
        let capabilities = CoachCapabilities.compose(disabledTools: [], referencesAdmitted: true)
        let callTool = try #require(capabilities.tool(named: "call_tool"))
        func verdict(_ name: String, _ arguments: String) -> CoachCapabilities.CallRejection? {
            capabilities.rejection(
                for: RawToolCall(id: "r", name: name, argumentsJSON: arguments),
                parsed: ToolInvocation.parse(callId: "r", name: name, argumentsJSON: arguments))
        }
        #expect(verdict("search_references", #"{"query":"q"}"#) == .notCallableByName("search_references"))
        #expect(verdict("nope", "{}") == .unavailable("nope"))
        #expect(verdict("speak", #"{"hint":""}"#) == .malformed(speakTool))
        #expect(verdict("call_tool", #"{"name":"search_references","arguments":"{}"}"#)
            == .malformed(searchReferencesTool))
        #expect(verdict("call_tool", #"{"name":"capture_screen","arguments":"{}"}"#) == .malformed(callTool))
        #expect(verdict("call_tool", #"{"name":"nope","arguments":"{}"}"#) == .unavailable("nope"))
        #expect(verdict("call_tool", #"{"name":"search_references","arguments":"{\"query\":\"q\"}"}"#) == nil)
        #expect(verdict("speak", #"{"hint":"a hint"}"#) == nil)
    }
    @Test func disablingPrepSearchAlsoDisablesDocumentReads() {
        for configured in [false, true] {
            let capabilities = CoachCapabilities.compose(
                disabledTools: ["search_references"], referencesAdmitted: configured)
            #expect(capabilities.tool(named: "read_reference") == nil)
            #expect(capabilities.deferredTools.isEmpty)
        }
    }

}
