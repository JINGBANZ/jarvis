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
        // Acoustic echo cancellation via VoiceProcessingIO is deliberately NOT enabled here. It came
        // up "successfully" (no throw) yet left the mic silent — the SCStream we start moments later
        // for system audio appears to change the audio route out from under the VPIO unit, and it
        // never recovers. A plain tap is robust. Trade-off: without AEC the other side's voice over
        // the speakers can bleed into the mic and be transcribed a second time on the "me" socket —
        // USE HEADPHONES. (Jarvis's own audio is already excluded on the system-audio side via
        // excludesCurrentProcessAudio.) Reviving AEC needs a setup that survives the SCStream route
        // change without silencing the mic; tracked as a follow-on.
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
