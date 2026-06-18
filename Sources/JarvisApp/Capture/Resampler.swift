@preconcurrency import AVFoundation

/// A stateful mono PCM16 sample-rate converter. AEC3 runs at 48 kHz but our wire format is 24 kHz,
/// so each AEC stream resamples up on the way in and (for the cleaned mic) back down on the way out.
/// The `AVAudioConverter` is built once and reused so its filter state carries across calls — keep
/// ONE `Resampler` per audio stream (don't share across the mic and system sides).
final class Resampler {
    private let converter: AVAudioConverter
    private let srcFormat: AVAudioFormat
    private let dstFormat: AVAudioFormat
    private let ratio: Double

    init?(fromHz: Double, toHz: Double) {
        guard let s = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: fromHz, channels: 1, interleaved: true),
              let d = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: toHz, channels: 1, interleaved: true),
              let c = AVAudioConverter(from: s, to: d) else { return nil }
        srcFormat = s; dstFormat = d; converter = c; ratio = toHz / fromHz
    }

    func convert(_ input: [Int16]) -> [Int16] {
        guard !input.isEmpty,
              let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(input.count)),
              let ch = inBuf.int16ChannelData else { return [] }
        inBuf.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: input.count) }

        let cap = AVAudioFrameCount(Double(input.count) * ratio) + 16
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: cap) else { return [] }
        // Supply the source buffer once, then signal no-more-data (Apple TN3136); the converter is
        // reused so its resampling history persists across calls for continuity.
        let fed = Fed()
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, inStatus in
            if fed.done { inStatus.pointee = .noDataNow; return nil }
            fed.done = true; inStatus.pointee = .haveData; return inBuf
        }
        guard status != .error, err == nil, outBuf.frameLength > 0,
              let outCh = outBuf.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: outCh[0], count: Int(outBuf.frameLength)))
    }
}

private final class Fed { var done = false }
