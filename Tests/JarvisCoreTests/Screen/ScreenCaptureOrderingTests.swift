import Testing
@testable import JarvisCore

@Suite struct ScreenCaptureOrderingTests {
    @Test func olderOrdinaryCaptureCannotAcknowledgeNewerScreenActivity() {
        #expect(!ScreenCaptureOrdering.canAcknowledge(
            capturedAt: 100,
            latestObservedChangeAt: 101,
            isMonitorSnapshot: false))
    }

    @Test func currentOrdinaryCaptureCanBecomeTheBaseline() {
        #expect(ScreenCaptureOrdering.canAcknowledge(
            capturedAt: 101,
            latestObservedChangeAt: 101,
            isMonitorSnapshot: false))
    }

    @Test func monitorCaptureUsesItsCandidateIDForOrdering() {
        #expect(ScreenCaptureOrdering.canAcknowledge(
            capturedAt: 100,
            latestObservedChangeAt: 101,
            isMonitorSnapshot: true))
    }
}
