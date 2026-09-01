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

    @Test func aFreshInstallHasNotAskedForScreenRecording() {
        #expect(PermissionPreferences(defaults: freshDefaults()).screenRecordingAsked
            == Defaults.Permissions.screenRecordingAsked)
    }

    @Test func askingIsRememberedAcrossLaunches() {
        // The only permission fact worth persisting: a later launch that still lacks the grant is
        // looking at a refusal rather than one waiting for a relaunch.
        let d = freshDefaults()
        PermissionPreferences(defaults: d).screenRecordingAsked = true

        #expect(PermissionPreferences(defaults: d).screenRecordingAsked)
    }
}
