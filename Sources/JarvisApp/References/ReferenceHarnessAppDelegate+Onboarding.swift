#if JARVIS_LIVE_E2E
import AppKit
import JarvisCore

extension ReferenceHarnessAppDelegate {
    func onboardingStopChecks(home: URL) async throws {
        for grants in [false, true] {
            let domain = "jarvis.onboarding-quit-harness.\(UUID())"
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let preferences = OnboardingPreferences(defaults: defaults)
            let brain = BrainPreferences(defaults: defaults)
            brain.route = BrainRoute(primary: BrainTarget(provider: .codexSubscription,
                modelID: BrainModelCatalog.defaultModel(for: .codexSubscription).id), fallbackTargets: [])
            let transcription = TranscriptionPreferences(defaults: defaults)
            transcription.provider = .appleSpeech
            let secrets = FileSecretStore(directoryURL: home.appendingPathComponent("onboarding-empty-secrets"))
            let gate = OnboardingGate(preferences: preferences,
                permissionPreferences: PermissionPreferences(defaults: defaults), secrets: secrets,
                keyStore: secrets, brainPreferences: brain, transcriptionPreferences: transcription)
            var releaseProbe: CheckedContinuation<Bool, Never>?
            var probeCount = 0
            var presentations = 0
            var completions = 0
            gate.testGrantProbe = {
                probeCount += 1
                return await withCheckedContinuation { releaseProbe = $0 }
            }
            gate.testOnPresentation = { presentations += 1 }
            gate.onFinished = { completions += 1 }
            let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
            let policy = NSApp.activationPolicy()
            let active = NSApp.isActive
            let beginning = Task { await gate.begin() }
            while releaseProbe == nil { await Task.yield() }
            gate.stop()
            releaseProbe?.resume(returning: grants)
            await beginning.value
            await gate.begin()
            try require(probeCount == 1 && presentations == 0 && completions == 0 && !preferences.isCompleted,
                        "Quit makes onboarding terminal after late \(grants ? "granted" : "missing") permissions")
            try require(Set(NSApp.windows.map(ObjectIdentifier.init)) == windows && NSApp.activationPolicy() == policy && NSApp.isActive == active,
                        "late onboarding completion neither presents nor activates UI")
            if !grants {
                let control = OnboardingGate(preferences: preferences,
                    permissionPreferences: PermissionPreferences(defaults: defaults), secrets: secrets,
                    keyStore: secrets, brainPreferences: brain, transcriptionPreferences: transcription)
                control.testGrantProbe = { false }
                control.testOnPresentation = { presentations += 1 }
                control.onFinished = { completions += 1 }
                await control.begin()
                try require(presentations == 1 && completions == 0 && !preferences.isCompleted,
                            "a live onboarding gate still attempts its missing-permission step")
                preferences.isCompleted = true
                await control.begin()
                try require(completions == 1, "completed onboarding still finishes without probing grants")
                control.stop()
                await control.begin()
                try require(completions == 1, "stopped completed onboarding cannot restart the app")
            }
        }
    }
}
#endif
