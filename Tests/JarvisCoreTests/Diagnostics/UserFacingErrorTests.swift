import Testing
@testable import JarvisCore

@Suite struct UserFacingErrorTests {
    @Test func fatalAlertsAndStops() {
        #expect(UserFacingError.Severity.fatal.showsAlert)
        #expect(UserFacingError.Severity.fatal.stopsSession)
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
