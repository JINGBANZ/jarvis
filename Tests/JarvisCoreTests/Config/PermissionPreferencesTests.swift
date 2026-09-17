import Testing
import Foundation
@testable import JarvisCore

@Suite struct PermissionPreferencesTests {
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
        let d = freshDefaults()
        PermissionPreferences(defaults: d).screenRecordingAsked = true

        #expect(PermissionPreferences(defaults: d).screenRecordingAsked)
    }
}
