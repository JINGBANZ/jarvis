import Testing
@testable import JarvisCore

@Suite struct TranscriptionFailureReasonTests {
    /// Account/credential/configuration reasons threaten every stream open to the provider, so a
    /// system-audio-side failure with one of these reasons must escalate the whole session rather
    /// than silently degrade to mic-only. See `AppDelegate`'s `themTranscriber.onTerminalFailure`.
    @Test func accountAndConfigurationReasonsAffectEveryStream() {
        #expect(TranscriptionFailureReason.authenticationFailed.affectsEveryStream)
        #expect(TranscriptionFailureReason.quotaExceeded.affectsEveryStream)
        #expect(TranscriptionFailureReason.accessDenied.affectsEveryStream)
        #expect(TranscriptionFailureReason.configurationRejected.affectsEveryStream)
    }

    /// `.connectionLost` is a transport blip specific to the one stream that reported it, not
    /// evidence the provider account itself is broken — it keeps today's degrade-to-mic-only
    /// behavior. `.appleSpeechUnavailable` is definitionally local: Apple Speech has no shared
    /// account/quota surface across streams.
    @Test func streamLocalReasonsDoNotAffectEveryStream() {
        #expect(!TranscriptionFailureReason.connectionLost.affectsEveryStream)
        #expect(!TranscriptionFailureReason.appleSpeechUnavailable.affectsEveryStream)
    }

    /// Enumerate every case so a future reason forces a deliberate escalate-or-degrade decision here
    /// instead of the property silently defaulting for an unhandled case.
    @Test func everyCaseHasAnExplicitDecision() {
        let escalating: Set<TranscriptionFailureReason> = [
            .authenticationFailed, .quotaExceeded, .accessDenied, .configurationRejected,
        ]
        let degrading: Set<TranscriptionFailureReason> = [.connectionLost, .appleSpeechUnavailable]
        #expect(escalating.union(degrading) == Set(TranscriptionFailureReason.allCases))
        for reason in TranscriptionFailureReason.allCases {
            #expect(reason.affectsEveryStream == escalating.contains(reason))
        }
    }
}
