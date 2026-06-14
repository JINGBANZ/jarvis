import Foundation
import JarvisCore

// TEMPORARY — replaced by real implementations in Tasks 12 (AudioInput) and 13 (RealtimeTranscriber).
// Signatures match the real types so AppDelegate is stable across the swap.

final class AudioInput: @unchecked Sendable {
    init(captureSystemAudio: Bool, onPCM: @escaping @Sendable (Data) -> Void) {}
    func start() {}
    func stop() {}
}

final class RealtimeTranscriber: @unchecked Sendable {
    var onTurnEnd: (@Sendable () -> Void)?
    var onSilence: (@Sendable (TimeInterval) -> Void)?
    init(apiKey: String, model: String, transcript: RollingTranscript, clock: Clock,
         silenceTimeout: TimeInterval = 8) {}
    func connect() {}
    func sendAudio(_ pcm: Data) {}
}
