import Testing
@testable import JarvisCore

@Suite struct UserFacingErrorTests {
    @Test func fatalAlertsAndStops() {
        #expect(UserFacingError.Severity.fatal.showsAlert)
        #expect(UserFacingError.Severity.fatal.stopsSession)
    }

    @Test func warningAlertsWithoutStopping() {
        // The preflight severity: the failed thing never started, so a live session must survive.
        #expect(UserFacingError.Severity.warning.showsAlert)
        #expect(!UserFacingError.Severity.warning.stopsSession)
    }

    @Test func terminalStopsWithoutAlert() {
        #expect(!UserFacingError.Severity.terminal.showsAlert)
        #expect(UserFacingError.Severity.terminal.stopsSession)
    }

    @Test func degradedNeitherAlertsNorStops() {
        #expect(!UserFacingError.Severity.degraded.showsAlert)
        #expect(!UserFacingError.Severity.degraded.stopsSession)
    }

    @Test func carriesFields() {
        let e = UserFacingError(title: "T", message: "M", severity: .fatal)
        #expect(e.title == "T")
        #expect(e.message == "M")
        #expect(e.severity == .fatal)
    }
}
