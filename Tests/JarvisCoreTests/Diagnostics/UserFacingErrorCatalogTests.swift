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

    @Test func brainCLIMissingIsFatalAndNamesTheProvider() {
        let e = UserFacingError.brainCLIMissing(provider: "Claude Code")
        #expect(e.severity == .fatal)
        #expect(e.title.contains("Claude Code"))
    }

    @Test func brainCLINotSignedInIsFatal() {
        // An authoritative signed-out marker (Codex) must fail the Start — a pipeline whose brain
        // can never answer would otherwise sit green while every turn errors.
        let e = UserFacingError.brainCLINotSignedIn(provider: "Codex CLI")
        #expect(e.severity == .fatal)
        #expect(e.severity.stopsSession)
    }

    @Test func brainCLISignInUnconfirmedStaysQuiet() {
        // The heuristic marker (Claude, Keychain-only credentials) can false-negative, so this must
        // warn without blocking the session.
        let e = UserFacingError.brainCLISignInUnconfirmed(provider: "Claude Code")
        #expect(e.severity == .degraded)
        #expect(!e.severity.showsAlert)
        #expect(!e.severity.stopsSession)
    }
}
