@preconcurrency import AVFoundation
import JarvisCore

/// Mic capture via AVAudioEngine, resampled to 24 kHz mono PCM16, delivered as Data chunks.
/// 24 kHz matches the Realtime API input format (audio/pcm rate 24000). This is the "me" side; the
/// "them" side (remote participants / system audio) is captured separately by `SystemAudioInput`
/// and tagged `.them`. Live behavior is validated by the human smoke run.
final class AudioInput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let onPCM: @Sendable (Data) -> Void

    init(onPCM: @escaping @Sendable (Data) -> Void) {
        self.onPCM = onPCM
    }

    func start() {
        let input = engine.inputNode
        // Acoustic echo cancellation: in a meeting WITHOUT headphones, the other side's voice plays
        // out the speakers and the mic would pick it up — then it gets transcribed on BOTH the "me"
        // and "them" sockets. VoiceProcessingIO cancels that speaker echo (and suppresses noise), the
        // same protection every reference impl applies to its mic. Best-effort: if the audio route
        // can't support it, we log and fall back to a plain tap rather than failing to capture.
        do { try input.setVoiceProcessingEnabled(true) }
        catch {
            // Loud on purpose: without AEC and without headphones, the other side's voice will leak
            // into the mic and be transcribed a second time on the "me" socket, mis-attributing their
            // words to the user. Recommend headphones in this state.
            jlog("⚠️ Jarvis audio: echo cancellation (AEC) unavailable — USE HEADPHONES, or the other "
                 + "side's audio may be double-transcribed as you. Falling back to raw mic: \(error)")
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inFormat, to: AudioPCM.target) else {
            jlog("Jarvis audio: cannot create converter"); return
        }
        let sink = onPCM
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            if let data = AudioPCM.pcm16Data(from: buffer, using: converter) { sink(data) }
        }
        do { try engine.start() } catch { jlog("Jarvis audio: engine start failed: \(error)") }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
