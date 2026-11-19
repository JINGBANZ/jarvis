import Testing
@testable import JarvisCore

@Suite struct TranscriptTimingResolverTests {
    @Test func nativeOffsetsWinAndPartialBoundariesSurviveFallback() {
        var timing = TranscriptTimingResolver()
        timing.recordAudio(startedAt: 2, endedAt: 15)
        timing.recordLocalSpeech(.ended(startedAt: 8, endedAt: 12, commitAt: 13))
        let native = timing.resolve(startedAt: 3, endedAt: 4, observedAt: 20,
                                    source: .providerOffsets, useLocalActivityEstimate: true)
        #expect(native.interval == SpeechInterval(startedAt: 3, endedAt: 4))
        #expect(native.source == .providerOffsets)
        let partial = timing.resolve(startedAt: 3, endedAt: nil, observedAt: 20,
                                     source: .providerOffsets, useLocalActivityEstimate: true)
        #expect(partial.interval == SpeechInterval(startedAt: 3, endedAt: 12))
        #expect(partial.source == .localActivityEstimate)
    }

    @Test func multipleFinalsReuseLocalActivityAndNewSpeechReplacesIt() {
        var timing = TranscriptTimingResolver()
        timing.recordLocalSpeech(.ended(startedAt: 8, endedAt: 12, commitAt: 13))
        for _ in 0..<3 {
            let result = timing.resolve(startedAt: nil, endedAt: nil, observedAt: 20,
                                        source: .providerOffsets, useLocalActivityEstimate: true)
            #expect(result.interval == SpeechInterval(startedAt: 8, endedAt: 12))
            #expect(result.source == .localActivityEstimate)
        }
        timing.recordLocalSpeech(.started(at: 21))
        timing.recordAudio(startedAt: 21, endedAt: 23)
        let ongoing = timing.resolve(startedAt: nil, endedAt: nil, observedAt: 24,
                                     source: .providerOffsets, useLocalActivityEstimate: true)
        #expect(ongoing.interval == SpeechInterval(startedAt: 21, endedAt: 23))
        #expect(ongoing.source == .audioWindowEstimate)
    }

    @Test func fallbackUsesWholeAudioWindowAndPreservesSingleKnownBoundary() {
        var timing = TranscriptTimingResolver()
        timing.recordAudio(startedAt: 3, endedAt: 4)
        timing.recordAudio(startedAt: 8, endedAt: 10)
        let full = timing.resolve(startedAt: nil, endedAt: nil, observedAt: 15,
                                  source: .providerOffsets, useLocalActivityEstimate: false)
        #expect(full.interval == SpeechInterval(startedAt: 3, endedAt: 10))
        #expect(full.source == .audioWindowEstimate)
        let start = timing.resolve(startedAt: 6, endedAt: .infinity, observedAt: 15,
                                   source: .providerOffsets, useLocalActivityEstimate: false)
        #expect(start.interval == SpeechInterval(startedAt: 6, endedAt: 10))
        let end = timing.resolve(startedAt: .nan, endedAt: 9, observedAt: 15,
                                 source: .providerOffsets, useLocalActivityEstimate: false)
        #expect(end.interval == SpeechInterval(startedAt: 3, endedAt: 9))
        timing.resetAudioWindow()
        let reset = timing.resolve(startedAt: nil, endedAt: nil, observedAt: 15,
                                   source: .providerOffsets, useLocalActivityEstimate: false)
        #expect(reset.interval == SpeechInterval(startedAt: 0, endedAt: 0))
    }

    @Test func delayedEndOnlyFinalKeepsNativeEndBeforeLaterLocalSpeech() {
        var timing = TranscriptTimingResolver()
        timing.recordAudio(startedAt: 0, endedAt: 20)
        timing.recordLocalSpeech(.ended(startedAt: 8, endedAt: 12, commitAt: 13))
        let result = timing.resolve(startedAt: nil, endedAt: 5, observedAt: 25,
                                    source: .providerOffsets, useLocalActivityEstimate: true)
        #expect(result.interval == SpeechInterval(startedAt: 0, endedAt: 5))
        #expect(result.source == .audioWindowEstimate)
    }

    @Test func availableCaptureEndSurvivesSmallReceiptClockSkew() {
        var timing = TranscriptTimingResolver()
        timing.recordAudio(startedAt: 8, endedAt: 12.02)
        timing.recordLocalSpeech(.started(at: 10))
        let result = timing.resolve(startedAt: nil, endedAt: nil, observedAt: 12,
                                    source: .providerOffsets, useLocalActivityEstimate: true)
        #expect(result.interval == SpeechInterval(startedAt: 10, endedAt: 12.02))
        #expect(result.source == .audioWindowEstimate)
    }

    @Test func negativeObservationAndFutureOrUnformattableOffsetsNeverLoseWordsOrEscapeFormat() {
        for observation in [-1.0, .nan, .infinity] {
            let resolved = TranscriptTimingResolver().resolve(
                startedAt: nil, endedAt: nil, observedAt: observation,
                source: .providerOffsets, useLocalActivityEstimate: true)
            let line = TranscriptLine(speaker: .me, text: "retained words", interval: resolved.interval,
                                      timingSource: resolved.source)
            #expect(line.interval == SpeechInterval(startedAt: 0, endedAt: 0))
            #expect(RollingTranscript.render([line]) == "[00:00-00:00] me: retained words")
        }
        var timing = TranscriptTimingResolver()
        timing.recordAudio(startedAt: 3, endedAt: 10)
        let valid = timing.resolve(startedAt: 6, endedAt: 9, observedAt: -1,
                                   source: .providerOffsets, useLocalActivityEstimate: false)
        #expect(valid.interval == SpeechInterval(startedAt: 6, endedAt: 9))
        #expect(valid.source == .providerOffsets)
        for invalidEnd in [100.0, 1e20, .infinity, .nan] {
            let result = timing.resolve(startedAt: 6, endedAt: invalidEnd, observedAt: 15,
                                        source: .providerOffsets, useLocalActivityEstimate: false)
            #expect(result.interval == SpeechInterval(startedAt: 6, endedAt: 10))
            #expect(result.source == .audioWindowEstimate)
        }
    }
}
