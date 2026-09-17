@preconcurrency import AVFoundation

/// Stateful: filter history carries across calls, so use one instance per audio stream.
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
        // Supply the source buffer once, then signal no data now (Apple TN3136).
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

    func reset() {
        converter.reset()
    }
}

// @unchecked: touched only within one synchronous `convert` call on one thread.
private final class Fed: @unchecked Sendable { var done = false }
