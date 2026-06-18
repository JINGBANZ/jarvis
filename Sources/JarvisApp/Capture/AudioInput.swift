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
        // A plain tap, deliberately NOT VoiceProcessingIO: Apple's VPIO came up "successfully" yet
        // left the mic silent — the SCStream we start moments later for system audio changes the
        // audio route out from under the VPIO unit and it never recovers (VPIO also ducks the very
        // SCStream audio we capture). Echo cancellation is instead done downstream by
        // `WebRTCEchoCanceller` (AEC3), which cleans this mic stream against the system audio as the
        // far-end reference — robust on any route, and no headphones required. See AppDelegate.start().
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
