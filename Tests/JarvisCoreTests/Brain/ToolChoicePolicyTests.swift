import Testing
@testable import JarvisCore

@Suite struct ToolChoicePolicyTests {
    private let tools = ["capture_screen", "speak", "stay_silent", "load_skill"].map {
        ToolDef(name: $0, description: "d", parametersJSON: "{}")
    }

    @Test func providerEnforcedSendsEveryToolAndTheChoiceAsAsked() {
        for choice in [ToolChoice.auto, .required, .allowed(["speak", "load_skill"]), .force("speak")] {
            let resolved = ToolChoicePolicy.providerEnforced.resolve(tools: tools, choice: choice)
            #expect(resolved.tools == tools)
            #expect(resolved.choice == choice)
        }
    }

    @Test func filteredAutoCarriesThePermittedSetInTheDeclaredTools() {
        let narrowed = ToolChoicePolicy.filteredAuto.resolve(
            tools: tools, choice: .allowed(["speak", "load_skill"]))
        #expect(narrowed.tools.map(\.name) == ["speak", "load_skill"])
        #expect(narrowed.choice == .auto)
        let forced = ToolChoicePolicy.filteredAuto.resolve(tools: tools, choice: .force("speak"))
        #expect(forced.tools.map(\.name) == ["speak"])
        #expect(forced.choice == .auto)
        for choice in [ToolChoice.auto, .required] {
            let resolved = ToolChoicePolicy.filteredAuto.resolve(tools: tools, choice: choice)
            #expect(resolved.tools == tools)
            #expect(resolved.choice == .auto)
        }
    }
}
