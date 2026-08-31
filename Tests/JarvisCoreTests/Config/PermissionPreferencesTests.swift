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

    @Test func freshInstallHasNeverStartedATap() {
        // Nothing proven yet, so the gate stays shut rather than assuming a grant macOS gives no
        // way to read.
        #expect(PermissionPreferences(defaults: freshDefaults()).systemAudioGranted
            == Defaults.Permissions.systemAudioGranted)
    }

    @Test func aStartedTapRoundTripsThroughDefaults() {
        let d = freshDefaults()
        PermissionPreferences(defaults: d).systemAudioGranted = true

        #expect(PermissionPreferences(defaults: d).systemAudioGranted)
    }

    @Test func aRevokedGrantIsRememberedAsRevoked() {
        let d = freshDefaults()
        PermissionPreferences(defaults: d).systemAudioGranted = true
        PermissionPreferences(defaults: d).systemAudioGranted = false

        #expect(!PermissionPreferences(defaults: d).systemAudioGranted)
    }
}
