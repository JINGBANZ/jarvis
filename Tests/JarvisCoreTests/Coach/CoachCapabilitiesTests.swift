import Testing
@testable import JarvisCore

/// The one value the app's brain composition and the coach loop both read, so the schemas a
/// local-agent process is warmed with are the schemas the loop later sends (#273).
@Suite struct CoachCapabilitiesTests {
    @Test func theThreeCoachingActionsComeFirstAndAlwaysInTheSameOrder() {
        #expect(CoachCapabilities.compose(disabledTools: [], prepSourcesConfigured: true)
            .tools.map(\.name) == ["capture_screen", "speak", "stay_silent", "search_prep_notes"])
        #expect(CoachCapabilities.default.tools.map(\.name)
            == ["capture_screen", "speak", "stay_silent"])
        #expect(CoachCapabilities.default.deferredTools.isEmpty)
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
        #expect(capabilities.callable(loaded: ["later"]).map(\.name)
            == ["capture_screen", "speak", "stay_silent", "later"])
        #expect(capabilities.catalogNames == ["later"])
        #expect(capabilities.tool(named: "later") == deferred)
        #expect(capabilities.tool(named: "nope") == nil)
    }
}
