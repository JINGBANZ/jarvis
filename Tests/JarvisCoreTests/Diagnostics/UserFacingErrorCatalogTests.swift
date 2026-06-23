import Testing
@testable import JarvisCore

/// The catalog is the single source of truth for *which* failures are loud. These tests lock in the
/// loudness of each canonical failure so a regression (e.g. silently downgrading a capture failure, or
/// making the graceful "them"-socket degrade pop a modal) is caught without a UI session.
@Suite struct UserFacingErrorCatalogTests {
    @Test func noAPIKeyIsFatal() {
        #expect(UserFacingError.noAPIKey.severity == .fatal)
        #expect(UserFacingError.noAPIKey.severity.showsAlert)
    }

    @Test func captureFailedIsFatalAndCarriesReason() {
        let e = UserFacingError.captureFailed(reason: "no input device")
        #expect(e.severity == .fatal)
        #expect(e.severity.stopsSession)
        #expect(e.message.contains("no input device"))
    }

    @Test func transcriptionStoppedIsFatal() {
        #expect(UserFacingError.transcriptionStopped.severity == .fatal)
    }

    @Test func systemAudioStoppedStaysQuiet() {
        // The graceful degrade: mic still works, so this must NOT alert or stop the session.
        #expect(UserFacingError.systemAudioStopped.severity == .degraded)
        #expect(!UserFacingError.systemAudioStopped.severity.showsAlert)
        #expect(!UserFacingError.systemAudioStopped.severity.stopsSession)
    }
}
