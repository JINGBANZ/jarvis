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
            disabledTools: ["capture_screen", "speak", "stay_silent", "not_a_tool"],
            prepSourcesConfigured: false)

        #expect(capabilities.tools.map(\.name) == ["capture_screen", "speak", "stay_silent"])
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

    /// The loader exists only while something remains to load, whether that is because the session
    /// composed no catalog or because the model has since loaded all of it.
    @Test func theLoaderDisappearsOnceEverythingIsLoaded() {
        let capabilities = CoachCapabilities.compose(
            disabledTools: [], prepSourcesConfigured: true)

        #expect(capabilities.callable(loaded: []).map(\.name)
            == ["capture_screen", "speak", "stay_silent", "load_tool"])
        #expect(capabilities.callable(loaded: ["search_prep_notes"]).map(\.name)
            == ["capture_screen", "speak", "stay_silent", "search_prep_notes"])
        // Still in `tools`, so a stale call is answered rather than refused as unknown.
        #expect(capabilities.tool(named: CoachCapabilities.loadToolName) != nil)
    }
}
