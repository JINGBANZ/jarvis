import Testing
import Foundation
@testable import JarvisCore

@Suite struct PermissionPreferencesTests {
    /// A fresh, isolated UserDefaults suite per test so nothing touches the real app domain.
    private func freshDefaults() -> UserDefaults {
        let suite = "PermissionPreferencesTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func freshInstallHasSeenNeitherTheChecklistNorATap() {
        let preferences = PermissionPreferences(defaults: freshDefaults())
        #expect(preferences.onboardingShown == Defaults.Permissions.onboardingShown)
        // Nothing proven yet, so Start blocks with a named permission rather than assuming a grant
        // macOS gives no way to read.
        #expect(preferences.systemAudioGranted == Defaults.Permissions.systemAudioGranted)
    }

    @Test func bothFlagsRoundTripThroughDefaults() {
        let d = freshDefaults()
        let written = PermissionPreferences(defaults: d)
        written.onboardingShown = true
        written.systemAudioGranted = true

        let reread = PermissionPreferences(defaults: d)
        #expect(reread.onboardingShown)
        #expect(reread.systemAudioGranted)
    }

    @Test func aRevokedGrantIsRememberedAsRevoked() {
        let d = freshDefaults()
        PermissionPreferences(defaults: d).systemAudioGranted = true
        PermissionPreferences(defaults: d).systemAudioGranted = false

        #expect(!PermissionPreferences(defaults: d).systemAudioGranted)
    }
}
