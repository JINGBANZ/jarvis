import Testing
@testable import JarvisCore

@Suite struct TranscriptFilteringTests {
    @Test func punctuationOnlyOutputIsDroppedForBothSpeakers() {
        #expect(TranscriptFiltering.meaningfulTranscript(".", speaker: .me) == nil)
        #expect(TranscriptFiltering.meaningfulTranscript("  …  ", speaker: .them) == nil)
    }

    @Test func captionArtifactsAreDroppedOnlyOnTheMicSide() {
        #expect(TranscriptFiltering.meaningfulTranscript("Thank you.", speaker: .me) == nil)
        // A turn-ending reply from the other side is real speech, not an artifact.
        #expect(TranscriptFiltering.meaningfulTranscript("Thank you.", speaker: .them) == "Thank you.")
    }

    @Test func realSpeechContainingADenylistedWordSurvives() {
        #expect(TranscriptFiltering.meaningfulTranscript("Thank you for the walkthrough", speaker: .me)
            == "Thank you for the walkthrough")
    }
}
