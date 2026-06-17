@preconcurrency import AVFoundation
import JarvisCore

/// Shared resampling for the two capture sources (mic via AVAudioEngine, system audio via
/// ScreenCaptureKit). Both must emit the SAME wire format the Realtime API expects: 24 kHz mono
/// PCM16, little-endian, interleaved. Whatever each source hands us (mic's native rate, or SCK's
/// 48 kHz float), an `AVAudioConverter` lands it on `target`.
enum AudioPCM {
    /// The Realtime API input format (audio/pcm rate 24000). One definition, shared by both sources.
    static let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: 24_000, channels: 1, interleaved: true)!

    /// Convert one source buffer to 24 kHz mono PCM16 bytes using a pre-built converter.
    /// Returns nil (and logs) on a converter error; a nil result is simply not forwarded.
    static func pcm16Data(from input: AVAudioPCMBuffer, using converter: AVAudioConverter) -> Data? {
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var err: NSError?
        // Sample-rate conversion may call the input block more than once per convert(): supply the
        // source buffer once, then signal no-more-data (Apple TN3136). A reference holder is used so
        // the input block doesn't mutate a captured var.
        let once = ConvertOnce()
        converter.convert(to: out, error: &err) { _, status in
            if once.consumed { status.pointee = .noDataNow; return nil }
            once.consumed = true
            status.pointee = .haveData
            return input
        }
        if let err { jlog("Jarvis audio convert error: \(err)"); return nil }
        return out.int16Data()
    }
}

/// One-shot flag for the AVAudioConverter input block (avoids mutating a captured var).
private final class ConvertOnce: @unchecked Sendable { var consumed = false }

private extension AVAudioPCMBuffer {
    /// Raw little-endian PCM16 bytes for the filled frames.
    func int16Data() -> Data? {
        guard let ch = int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(frameLength) * MemoryLayout<Int16>.size)
    }
}
