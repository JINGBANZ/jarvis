import Testing
@testable import JarvisCore

@Suite struct RobotHubTests {
    @Test func everyPartGetsASlotFromItsSavedSettings() {
        let state = RobotHub.state(for: .fixture())
        #expect(Set(state.slots.keys) == Set(RobotPart.allCases))
        #expect(state.slots[.brain]
            == RobotSlotState(value: "GPT-6 Sol", detail: "VIA CODEX", tone: .normal, level: 3))
        #expect(state.slots[.ear]
            == RobotSlotState(value: "OpenAI · GPT-4o", detail: "HEARS EN", tone: .normal, level: nil))
        #expect(state.slots[.eye]?.detail == "CHROME TEXT OFF")
        #expect(state.slots[.mouth]?.detail == "25 PT TEXT")
    }

    @Test func aSettingsChangeChangesTheState() {
        #expect(RobotHub.state(for: .fixture(effort: .low)) != RobotHub.state(for: .fixture()))
        #expect(RobotHub.state(for: .fixture(effort: .low)).slots[.brain]?.level == 1)
    }

    @Test func withoutReadinessThereAreNoLightsAndNoMeter() {
        let state = RobotHub.state(for: .fixture())
        #expect(state.meter == nil)
        #expect(!state.isLive)
        #expect(state.slots.values.allSatisfy { $0.health == nil })
    }

    @Test func allReadyShowsTheReadyMeter() {
        let state = RobotHub.state(for: .fixture(readiness: .fixture()))
        #expect(state.meter == RobotHubMeter(
            ready: [true, true, true, true], label: "SYSTEMS READY 4/4", tone: .normal))
        #expect(state.slots[.brain]?.health == .ready)
    }

    @Test func attentionReplacesTheSlotLineAndLightsTheMeter() {
        let state = RobotHub.state(for: .fixture(readiness: .fixture(granted: [.microphone])))
        #expect(state.slots[.eye]?.detail == "SCREEN RECORDING IS OFF")
        #expect(state.slots[.eye]?.tone == .attention)
        #expect(state.meter == RobotHubMeter(
            ready: [true, true, false, true], label: "NEEDS YOU 3/4", tone: .attention))
    }

    @Test func aLiveSessionNamesTheBrainInUse() {
        let codex = BrainTarget(provider: .codexSubscription, modelID: "gpt-6-sol")
        let openAI = BrainTarget(provider: .openAI, modelID: "gpt-6-sol")
        let route = BrainRoute(primary: codex, fallbackTargets: [openAI])
        let onPrimary = RobotHub.state(for: .fixture(route: route, readiness: .fixture(), activeTarget: codex))
        #expect(onPrimary.isLive)
        #expect(onPrimary.slots[.brain]?.detail == "THINKING WITH PRIMARY")
        #expect(onPrimary.slots[.brain]?.tone == .live)
        #expect(onPrimary.meter?.label == "ONLINE · COACHING")
        #expect(onPrimary.meter?.tone == .live)

        let onFallback = RobotHub.state(for: .fixture(route: route, activeTarget: openAI))
        #expect(onFallback.slots[.brain]?.detail == "THINKING WITH FALLBACK 1")

        let elsewhere = BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5-5")
        #expect(RobotHub.state(for: .fixture(route: route, activeTarget: elsewhere))
            .slots[.brain]?.detail == "THINKING WITH CLAUDE CODE")
    }

    @Test func aBrainProblemOutranksTheLiveLine() {
        let openAI = BrainTarget(provider: .openAI, modelID: "gpt-6-sol")
        let state = RobotHub.state(for: .fixture(
            route: BrainRoute(primary: openAI, fallbackTargets: []),
            readiness: .fixture(credentials: []),
            activeTarget: openAI))
        #expect(state.slots[.brain]?.detail == "ADD AN OPENAI KEY")
        #expect(state.slots[.brain]?.tone == .attention)
    }
}
