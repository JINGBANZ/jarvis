import Testing
@testable import JarvisCore

@Suite struct TranscriptionAudioFormatTests {
    @Test func sharedPCMContractConvertsBytesAndDuration() {
        let format = TranscriptionAudioFormat.pcm16Mono24k

        #expect(format.sampleRate == 24_000)
        #expect(format.channelCount == 1)
        #expect(format.bytesPerSample == 2)
        #expect(format.bytesPerSecond == 48_000)
        #expect(format.duration(forByteCount: 96_000) == 2)
        #expect(format.byteCount(forDuration: 2.5) == 120_000)
    }

    @Test func invalidDurationsDoNotCreateBufferCapacity() {
        let format = TranscriptionAudioFormat.pcm16Mono24k

        #expect(format.byteCount(forDuration: -.infinity) == 0)
        #expect(format.byteCount(forDuration: 0) == 0)
        #expect(format.duration(forByteCount: -1) == 0)
    }

    @Test func geminiCapturesAtSixteenKilohertzAndTheOthersAtTwentyFour() {
        #expect(TranscriptionProvider.gemini.audioFormat == .pcm16Mono16k)
        #expect(TranscriptionProvider.openAI.audioFormat == .pcm16Mono24k)
        #expect(TranscriptionProvider.appleSpeech.audioFormat == .pcm16Mono24k)
    }

    @Test func sixteenKilohertzFormatDerivesItsOwnByteMath() {
        let format = TranscriptionAudioFormat.pcm16Mono16k
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        #expect(format.bytesPerSecond == 32_000)
        #expect(format.byteCount(forDuration: 0.1) == 3_200)
        #expect(format.duration(forByteCount: 32_000) == 1.0)
    }
}
