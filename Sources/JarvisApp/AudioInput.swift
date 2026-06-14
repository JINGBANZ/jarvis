@preconcurrency import AVFoundation
import JarvisCore

/// Mic capture via AVAudioEngine, downsampled to 16 kHz mono PCM16, delivered as Data chunks.
/// System-audio capture (the "them" side) is a documented follow-on; mic is the critical path
/// (spec §6). Live behavior is validated by the human smoke run.
final class AudioInput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let onPCM: @Sendable (Data) -> Void
    private let captureSystemAudio: Bool
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 16_000, channels: 1, interleaved: true)!

    init(captureSystemAudio: Bool, onPCM: @escaping @Sendable (Data) -> Void) {
        self.onPCM = onPCM
        self.captureSystemAudio = captureSystemAudio
    }

    func start() {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inFormat, to: targetFormat) else {
            NSLog("Jarvis audio: cannot create converter"); return
        }
        let target = targetFormat
        let sink = onPCM
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            let ratio = target.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                status.pointee = .haveData
                return buffer
            }
            if let err { NSLog("Jarvis audio convert error: \(err)"); return }
            if let data = out.int16Data() { sink(data) }
        }
        do { try engine.start() } catch { NSLog("Jarvis audio: engine start failed: \(error)") }
        // System-audio tap (ScreenCaptureKit SCStream with capturesAudio = true) is the documented
        // extension point: feed the same `onPCM` with a `.them` speaker tag. First feature cut if it
        // threatens the timeline (spec §6); mic above is the critical path.
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

private extension AVAudioPCMBuffer {
    /// Raw little-endian PCM16 bytes for the filled frames.
    func int16Data() -> Data? {
        guard let ch = int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(frameLength) * MemoryLayout<Int16>.size)
    }
}
