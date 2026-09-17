import Testing
@testable import JarvisCore

@Suite struct TranscriptFilteringTests {
    @Test func punctuationOnlyOutputIsDroppedForBothSpeakers() {
        #expect(TranscriptFiltering.meaningfulTranscript(".", speaker: .me) == nil)
        #expect(TranscriptFiltering.meaningfulTranscript("  …  ", speaker: .them) == nil)
    }

    @Test func captionArtifactsAreDroppedOnlyOnTheMicSide() {
        #expect(TranscriptFiltering.meaningfulTranscript("Thank you.", speaker: .me) == nil)
        #expect(TranscriptFiltering.meaningfulTranscript("Thank you.", speaker: .them) == "Thank you.")
    }

    @Test func realSpeechContainingADenylistedWordSurvives() {
        #expect(TranscriptFiltering.meaningfulTranscript("Thank you for the walkthrough", speaker: .me)
            == "Thank you for the walkthrough")
    }
}
