import Testing
@testable import JarvisCore

@Suite struct RobotHubTests {
    @Test func aTemporarilyUnavailablePrimaryCannotShowGreenReadiness() {
        let claude = BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5-5")
        let failure = ProviderFailure(
            source: .brain(.claudeSubscription), stage: .process, category: .unavailable,
            disposition: .temporary, identity: .init(), message: "The subscription is temporarily unavailable. Try again.")
        var readiness = RobotReadiness.fixture(signedOut: [.codexSubscription])
        readiness.subscriptions[.claudeSubscription] = .unavailable(failure)
        let state = RobotHub.state(for: .fixture(
            route: BrainRoute(primary: claude, fallbackTargets: [
                BrainTarget(provider: .codexSubscription, modelID: "gpt-6.1-sol"),
            ]), readiness: readiness))
        #expect(state.slots[.brain]?.health?.isReady == false)
        #expect(state.meter?.tone != .normal)
        #expect(state.meter?.label != "SYSTEMS READY 4/4")
        #expect(state.slots[.brain]?.detail == "NO BRAIN AVAILABLE")
        #expect(state.slots[.brain]?.tone == .blocked)
        #expect(state.meter?.tone == .blocked)
        #expect(state.meter?.signals == [.blocked, .normal, .normal, .normal])
        #expect(state.meter?.label == "NOT READY 3/4")
    }

    @Test func everyPartGetsASlotFromItsSavedSettings() {
        let state = RobotHub.state(for: .fixture())
        #expect(Set(state.slots.keys) == Set(RobotPart.allCases))
        #expect(state.slots[.brain]
            == RobotSlotState(value: "GPT-6.1 Sol", detail: "VIA CODEX", tone: .normal, level: 3))
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
            signals: [.normal, .normal, .normal, .normal], label: "SYSTEMS READY 4/4", tone: .normal))
        #expect(state.slots[.brain]?.health == .ready)
    }

    @Test func attentionReplacesTheSlotLineAndLightsTheMeter() {
        let state = RobotHub.state(for: .fixture(readiness: .fixture(granted: [.microphone])))
        #expect(state.slots[.eye]?.detail == "SCREEN RECORDING IS OFF")
        #expect(state.slots[.eye]?.tone == .attention)
        #expect(state.meter == RobotHubMeter(
            signals: [.normal, .normal, .attention, .normal], label: "NEEDS YOU 3/4", tone: .attention))
    }

    @Test func aLiveSessionNamesTheBrainInUse() {
        let codex = BrainTarget(provider: .codexSubscription, modelID: "gpt-6.1-sol")
        let openAI = BrainTarget(provider: .openAI, modelID: "gpt-6.1-sol")
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
        let openAI = BrainTarget(provider: .openAI, modelID: "gpt-6.1-sol")
        let state = RobotHub.state(for: .fixture(
            route: BrainRoute(primary: openAI, fallbackTargets: []),
            readiness: .fixture(credentials: []),
            activeTarget: openAI))
        #expect(state.slots[.brain]?.detail == "NO BRAIN AVAILABLE")
        #expect(state.slots[.brain]?.tone == .blocked)
    }

    @Test func anUnavailablePrimaryWithAUsableFallbackIsAmber() {
        let route = BrainRoute(
            primary: BrainTarget(provider: .codexSubscription, modelID: "gpt-6.1-sol"),
            fallbackTargets: [BrainTarget(provider: .gemini, modelID: "gemini-3.8-flash")])
        let state = RobotHub.state(for: .fixture(route: route, readiness: .fixture(signedOut: [.codexSubscription])))
        #expect(state.slots[.brain]?.detail == "PRIMARY UNAVAILABLE")
        #expect(state.slots[.brain]?.tone == .attention)
        #expect(state.meter?.tone == .attention)
        #expect(state.meter?.signals == [.attention, .normal, .normal, .normal])
    }

    @Test func aPendingCredentialCheckDoesNotShowGreen() {
        var readiness = RobotReadiness.fixture()
        readiness.subscriptions.removeAll()
        let state = RobotHub.state(for: .fixture(readiness: readiness))
        #expect(state.slots[.brain]?.detail == "CHECKING CONNECTIONS")
        #expect(state.meter?.label == "CHECKING 3/4")
        #expect(state.meter?.tone == .attention)
    }
}
