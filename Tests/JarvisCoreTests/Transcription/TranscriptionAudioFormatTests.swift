import Testing
@testable import JarvisCore

@Suite struct TranscriptionAudioFormatTests {
    @Test func sharedPCMContractConvertsBytesAndDuration() {
        let format = TranscriptionAudioFormat.pcm16Mono

        #expect(format.sampleRate == 24_000)
        #expect(format.channelCount == 1)
        #expect(format.bytesPerSample == 2)
        #expect(format.bytesPerSecond == 48_000)
        #expect(format.duration(forByteCount: 96_000) == 2)
        #expect(format.byteCount(forDuration: 2.5) == 120_000)
    }

    @Test func invalidDurationsDoNotCreateBufferCapacity() {
        let format = TranscriptionAudioFormat.pcm16Mono

        #expect(format.byteCount(forDuration: -.infinity) == 0)
        #expect(format.byteCount(forDuration: 0) == 0)
        #expect(format.duration(forByteCount: -1) == 0)
    }
}
