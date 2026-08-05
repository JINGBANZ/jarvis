import CJarvisAEC
import JarvisCore

/// Thin Swift owner for classic WebRTC VAD. Capture feeds post-AEC 48 kHz PCM in arbitrary chunks;
/// the framer supplies the exact 10 ms blocks required by the native detector.
final class WebRTCVoiceActivityDetector {
    private let vad: OpaquePointer
    private let sampleRate: Int32
    private let frameSamples: Int
    private var framer: PCM16Framer
    private var reportedProcessingFailure = false

    init?(sampleRate: Int32 = 48_000, aggressiveness: Int32 = 2) {
        guard let vad = jarvis_vad_create(aggressiveness) else { return nil }
        self.vad = vad
        self.sampleRate = sampleRate
        frameSamples = Int(sampleRate) / 100
        framer = PCM16Framer(frameSize: frameSamples)
    }

    /// Returns one decision per complete 10 ms frame; incomplete samples stay in the framer.
    func classify(_ pcm16: [Int16]) -> [Bool] {
        framer.push(pcm16).map { frame in
            let result = frame.withUnsafeBufferPointer { samples in
                jarvis_vad_process(
                    vad,
                    sampleRate,
                    samples.baseAddress,
                    Int32(frameSamples))
            }
            if result < 0, !reportedProcessingFailure {
                reportedProcessingFailure = true
                jlog("Jarvis: WebRTC VAD rejected a 48 kHz/10 ms frame")
            }
            return result == 1
        }
    }

    deinit { jarvis_vad_destroy(vad) }
}
