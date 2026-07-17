import Testing
@testable import JarvisCore

@Suite struct ScreenActivityDetectorTests {
    @Test func idleAfterQuiescenceReportsOnceUntilAcknowledged() throws {
        var detector = ScreenActivityDetector(
            quiescenceInterval: 1,
            minimumChangedAreaRatio: 0.02)

        #expect(detector.observe(.idle, at: 0) == .idle)
        #expect(detector.observe(.contentChanged(changedAreaRatio: 0.4), at: 1)
                == .waitingForQuiescence)
        #expect(detector.observe(.idle, at: 1.99) == .waitingForQuiescence)

        let result = detector.observe(.idle, at: 2)
        let id = try #require(stableCandidateID(from: result))
        #expect(detector.observe(.idle, at: 3) == .awaitingAcknowledgement(id))
        let acknowledged = detector.acknowledge(id)
        #expect(acknowledged)
        #expect(detector.observe(.idle, at: 4) == .idle)
    }

    @Test func continuousSignificantChangesKeepRestartingQuiescence() {
        var detector = ScreenActivityDetector(
            quiescenceInterval: 2,
            minimumChangedAreaRatio: 0.01)

        for timestamp in [0.0, 1.0, 2.0, 3.0] {
            #expect(detector.observe(.contentChanged(changedAreaRatio: 0.2), at: timestamp)
                    == .waitingForQuiescence)
        }
        #expect(detector.observe(.idle, at: 4.99) == .waitingForQuiescence)
        #expect(stableCandidateID(from: detector.observe(.idle, at: 5)) != nil)
    }

    @Test func subThresholdChangesAreIgnoredWithoutRestartingCandidate() {
        var detector = ScreenActivityDetector(
            quiescenceInterval: 1,
            minimumChangedAreaRatio: 0.05)

        #expect(detector.observe(.contentChanged(changedAreaRatio: 0.01), at: 0) == .ignored)
        #expect(detector.observe(.contentChanged(changedAreaRatio: 0.4), at: 1)
                == .waitingForQuiescence)
        #expect(detector.observe(.contentChanged(changedAreaRatio: 0.049), at: 1.9) == .ignored)
        #expect(stableCandidateID(from: detector.observe(.idle, at: 2)) != nil)
    }

    @Test func rejectedCandidateCanReportAgainButDoesNotSpamBeforeRejection() throws {
        var detector = ScreenActivityDetector(
            quiescenceInterval: 0.5,
            minimumChangedAreaRatio: 0.01)
        _ = detector.observe(.contentChanged(changedAreaRatio: 0.3), at: 0)

        let id = try #require(stableCandidateID(from: detector.observe(.idle, at: 0.5)))
        #expect(detector.observe(.idle, at: 1) == .awaitingAcknowledgement(id))
        let rejected = detector.reject(id)
        #expect(rejected)
        #expect(detector.observe(.idle, at: 1) == .stableChange(id))
        #expect(detector.observe(.idle, at: 2) == .awaitingAcknowledgement(id))
    }

    @Test func staleAcknowledgementCannotClearNewerCandidate() throws {
        var detector = ScreenActivityDetector(
            quiescenceInterval: 1,
            minimumChangedAreaRatio: 0.01)
        _ = detector.observe(.contentChanged(changedAreaRatio: 0.2), at: 0)
        let firstID = try #require(stableCandidateID(from: detector.observe(.idle, at: 1)))

        #expect(detector.observe(.contentChanged(changedAreaRatio: 0.3), at: 2)
                == .waitingForQuiescence)
        let acknowledgedStaleCandidate = detector.acknowledge(firstID)
        #expect(!acknowledgedStaleCandidate)
        let secondID = try #require(stableCandidateID(from: detector.observe(.idle, at: 3)))
        #expect(secondID != firstID)
        let acknowledgedCurrentCandidate = detector.acknowledge(secondID)
        #expect(acknowledgedCurrentCandidate)
    }

    @Test func newerAwaitingCandidateCanBeRediscoveredAfterConsumerWasBusy() throws {
        var detector = ScreenActivityDetector(
            quiescenceInterval: 1,
            minimumChangedAreaRatio: 0.01)
        _ = detector.observe(.contentChanged(changedAreaRatio: 0.2), at: 0)
        let firstID = try #require(stableCandidateID(from: detector.observe(.idle, at: 1)))
        _ = detector.observe(.contentChanged(changedAreaRatio: 0.3), at: 2)
        let secondID = try #require(stableCandidateID(from: detector.observe(.idle, at: 3)))

        let acknowledgedStaleCandidate = detector.acknowledge(firstID)
        #expect(!acknowledgedStaleCandidate)
        #expect(detector.observe(.idle, at: 4) == .awaitingAcknowledgement(secondID))
    }

    @Test func restartReconciliationChangeProducesCaptureAfterFirstQuietWindow() {
        var detector = ScreenActivityDetector(
            quiescenceInterval: 1,
            minimumChangedAreaRatio: 0.01)

        #expect(detector.observe(.contentChanged(changedAreaRatio: 1), at: 10)
                == .waitingForQuiescence)
        #expect(detector.observe(.idle, at: 10.5) == .waitingForQuiescence)
        #expect(stableCandidateID(from: detector.observe(.idle, at: 11)) != nil)
    }

    @Test func resetClearsCandidateButDoesNotReuseCandidateIdentity() throws {
        var detector = ScreenActivityDetector(
            quiescenceInterval: 0,
            minimumChangedAreaRatio: 0)
        _ = detector.observe(.contentChanged(changedAreaRatio: 0), at: 0)
        let firstID = try #require(stableCandidateID(from: detector.observe(.idle, at: 0)))

        detector.reset()
        #expect(detector.observe(.idle, at: 0) == .idle)
        _ = detector.observe(.contentChanged(changedAreaRatio: 0), at: 0)
        let secondID = try #require(stableCandidateID(from: detector.observe(.idle, at: 0)))
        #expect(secondID != firstID)
    }

    private func stableCandidateID(
        from result: ScreenActivityDetector.ObservationResult
    ) -> ScreenActivityDetector.CandidateID? {
        guard case .stableChange(let id) = result else { return nil }
        return id
    }
}
