import Foundation
import JarvisCore

/// Constructs the two provider endpoints from one immutable Start snapshot. Provider selection is
/// resolved before capture begins and never changes inside the live session.
enum TranscriptionSessionFactory {
    static func make(
        provider: TranscriptionProvider,
        apiKey: String,
        appleSpeechLocale: Locale?,
        speaker: Speaker,
        transcript: RollingTranscript,
        clock: Clock,
        config: Config,
        networkStatus: @escaping @Sendable () -> String
    ) -> any TranscriptionSession {
        switch provider {
        case .openAI:
            RealtimeTranscriber(
                apiKey: apiKey,
                model: config.transcriptionModel,
                speaker: speaker,
                transcript: transcript,
                clock: clock,
                silenceTimeout: config.silenceTimeoutSeconds,
                silenceMaxInterval: config.silenceMaxIntervalSeconds,
                silenceIdleCutoff: speaker == .me
                    ? config.silenceIdleCutoffSeconds
                    : .infinity,
                silenceDurationMs: config.vadSilenceDurationMs,
                noiseReduction: config.audioNoiseReduction,
                turnDebounce: config.turnDebounceSeconds,
                maxBufferedAudioSeconds: config.maxBufferedAudioSeconds,
                readyTimeout: config.realtimeReadyTimeoutSeconds,
                pingInterval: config.realtimePingIntervalSeconds,
                pongTimeout: config.realtimePongTimeoutSeconds,
                networkStatus: networkStatus)
        case .appleSpeech:
            if #available(macOS 26.0, *), let appleSpeechLocale {
                AppleSpeechTranscriber(
                    locale: appleSpeechLocale,
                    speaker: speaker,
                    transcript: transcript,
                    clock: clock,
                    silenceTimeout: config.silenceTimeoutSeconds,
                    silenceMaxInterval: config.silenceMaxIntervalSeconds,
                    silenceIdleCutoff: speaker == .me
                        ? config.silenceIdleCutoffSeconds
                        : .infinity,
                    turnDebounce: config.turnDebounceSeconds,
                    maxBufferedAudioSeconds: config.maxBufferedAudioSeconds)
            } else {
                preconditionFailure("Apple Speech must be prepared before constructing its session")
            }
        }
    }
}
