import Testing
@testable import JarvisCore

@Suite struct SystemAudioTimelineTests {
    @Test func emptyTapStillAdvancesRealtimeVADClock() {
        #expect(SystemAudioTimeline.preservingSamples([], minimumFrameCount: 480)
            == Array(repeating: 0, count: 480))
    }

    @Test func shortTapPreservesSamplesAndPadsOnlyMissingSilence() {
        #expect(SystemAudioTimeline.preservingSamples([10, 20], minimumFrameCount: 4)
            == [10, 20, 0, 0])
    }

    @Test func longTapIsNeverTruncatedForTranscription() {
        #expect(SystemAudioTimeline.preservingSamples([10, 20, 30, 40], minimumFrameCount: 2)
            == [10, 20, 30, 40])
    }
}
