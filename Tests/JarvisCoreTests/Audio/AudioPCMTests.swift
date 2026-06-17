@preconcurrency import AVFoundation
import Testing
@testable import JarvisCore

@Suite struct AudioPCMTests {
    /// A mono float32 buffer of `frames` samples all set to `value`, at `sampleRate`.
    private func floatBuffer(sampleRate: Double, frames: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let p = buf.floatChannelData![0]
        for i in 0..<Int(frames) { p[i] = value }
        return buf
    }

    /// Reinterpret the produced little-endian PCM16 bytes as Int16 samples.
    private func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    /// Same-rate (24 kHz) float → the 24 kHz PCM16 wire format: frame count is preserved exactly
    /// (no resampling), output is 2 bytes/sample, and amplitude maps float→Int16 correctly.
    @Test func convertsSameRateFloatToPCM16() throws {
        let src = floatBuffer(sampleRate: 24_000, frames: 480, value: 0.5)
        let converter = try #require(AVAudioConverter(from: src.format, to: AudioPCM.target))
        let data = try #require(AudioPCM.pcm16Data(from: src, using: converter))
        #expect(data.count == 480 * 2)            // 480 frames × 2 bytes, no rate change
        let s = samples(data)
        #expect(s.count == 480)
        let expected = Int16(0.5 * Float(Int16.max))
        #expect(abs(Int(s.first ?? 0) - Int(expected)) <= 2)   // 0.5 → ~half full-scale
        #expect(abs(Int(s.last ?? 0) - Int(expected)) <= 2)
    }

    /// 48 kHz float (what ScreenCaptureKit hands back) downsamples to ~half the frames at 24 kHz,
    /// staying a whole number of 16-bit samples. Tolerance covers resampler priming/latency.
    @Test func downsamples48kTo24k() throws {
        let src = floatBuffer(sampleRate: 48_000, frames: 960, value: 0.25)
        let converter = try #require(AVAudioConverter(from: src.format, to: AudioPCM.target))
        let data = try #require(AudioPCM.pcm16Data(from: src, using: converter))
        #expect(!data.isEmpty)
        #expect(data.count % 2 == 0)              // whole Int16 samples
        let outFrames = data.count / 2
        #expect(outFrames >= 400 && outFrames <= 520)   // ~480 (= 960 / 2), with resampler slack
        // Values, not just length: a constant 0.25 input must resample to a near-constant
        // ~0.25·full-scale, so a regression that preserved frame count but corrupted amplitude
        // (wrong channel/endianness/buffer) is caught. Skip edge frames for resampler priming.
        let s = samples(data)
        let mid = Array(s.dropFirst(8).dropLast(8))
        let expected = Int(0.25 * Float(Int16.max))
        #expect(!mid.isEmpty)
        #expect(mid.allSatisfy { abs(Int($0) - expected) <= 400 })
    }

    /// A zero-length buffer yields NON-NIL empty data (distinct from the nil-on-error path) — the
    /// callback simply forwards nothing.
    @Test func emptyBufferProducesEmptyData() throws {
        let src = floatBuffer(sampleRate: 24_000, frames: 0, value: 0)
        let converter = try #require(AVAudioConverter(from: src.format, to: AudioPCM.target))
        let data = try #require(AudioPCM.pcm16Data(from: src, using: converter))   // non-nil…
        #expect(data.isEmpty)                                                       // …and empty
    }
}
