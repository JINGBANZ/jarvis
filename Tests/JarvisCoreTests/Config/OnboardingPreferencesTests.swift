import Foundation
import Testing
@testable import JarvisCore

@Suite struct OnboardingPreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "OnboardingPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func aFreshInstallHasNotCompletedOnboarding() {
        #expect(OnboardingPreferences(defaults: freshDefaults()).isCompleted
            == Defaults.Onboarding.completed)
        #expect(!Defaults.Onboarding.completed)
    }

    @Test func completionIsRememberedAcrossLaunches() {
        let defaults = freshDefaults()
        OnboardingPreferences(defaults: defaults).isCompleted = true

        #expect(OnboardingPreferences(defaults: defaults).isCompleted)
    }
}
