@preconcurrency import AVFoundation
import JarvisCore

/// Mic capture via AVAudioEngine, resampled to 24 kHz mono PCM16, delivered as Data chunks.
/// 24 kHz matches the Realtime API input format (audio/pcm rate 24000). System-audio capture
/// (the "them" side) is a documented follow-on; mic is the critical path (spec §6). Live behavior
/// is validated by the human smoke run.
final class AudioInput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let onPCM: @Sendable (Data) -> Void
    private let captureSystemAudio: Bool
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 24_000, channels: 1, interleaved: true)!

    init(captureSystemAudio: Bool, onPCM: @escaping @Sendable (Data) -> Void) {
        self.onPCM = onPCM
        self.captureSystemAudio = captureSystemAudio
    }

    func start() {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inFormat, to: targetFormat) else {
            jlog("Jarvis audio: cannot create converter"); return
        }
        let target = targetFormat
        let sink = onPCM
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            let ratio = target.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var err: NSError?
            // Sample-rate conversion may call the input block more than once per convert():
            // supply the source buffer once, then signal no-more-data (Apple TN3136). A reference
            // holder is used so the @Sendable input block doesn't mutate a captured var.
            let once = ConvertOnce()
            converter.convert(to: out, error: &err) { _, status in
                if once.consumed { status.pointee = .noDataNow; return nil }
                once.consumed = true
                status.pointee = .haveData
                return buffer
            }
            if let err { jlog("Jarvis audio convert error: \(err)"); return }
            if let data = out.int16Data() { sink(data) }
        }
        do { try engine.start() } catch { jlog("Jarvis audio: engine start failed: \(error)") }
        // System-audio tap (ScreenCaptureKit SCStream with capturesAudio = true) is the documented
        // extension point: feed the same `onPCM` with a `.them` speaker tag. First feature cut if it
        // threatens the timeline (spec §6); mic above is the critical path.
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
