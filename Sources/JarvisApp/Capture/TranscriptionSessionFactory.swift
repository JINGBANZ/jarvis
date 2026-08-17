import Foundation
import JarvisCore

/// Constructs the two provider endpoints from one immutable Start snapshot. Provider selection is
/// resolved before capture begins and never changes inside the live session.
enum TranscriptionSessionFactory {
    static func make(
        configuration: TranscriptionConfiguration,
        apiKey: String,
        appleSpeechLocale: Locale?,
        speaker: Speaker,
        transcript: RollingTranscript,
        clock: Clock,
        sessionStart: TimeInterval,
        config: Config,
        networkStatus: @escaping @Sendable () -> String,
        benchmark: TranscriptionBenchmarkInstrumentation? = nil
    ) -> any TranscriptionSession {
        switch configuration.provider {
        case .openAI:
            RealtimeTranscriber(
                apiKey: apiKey,
                model: configuration.openAIModel,
                expectedLanguages: configuration.openAIExpectedLanguages,
                speaker: speaker,
                transcript: transcript,
                clock: clock,
                sessionStart: sessionStart,
                silenceTimeout: config.silenceTimeoutSeconds,
                silenceMaxInterval: config.silenceMaxIntervalSeconds,
                silenceIdleCutoff: speaker == .me
                    ? config.silenceIdleCutoffSeconds
                    : .infinity,
                silenceDurationMs: config.vadSilenceDurationMs,
                noiseReduction: config.audioNoiseReduction,
                transcriptBatchingWindow: config.transcriptBatchingWindowSeconds,
                maxBufferedAudioSeconds: config.maxBufferedAudioSeconds,
                readyTimeout: config.realtimeReadyTimeoutSeconds,
                pingInterval: config.realtimePingIntervalSeconds,
                pongTimeout: config.realtimePongTimeoutSeconds,
                networkStatus: networkStatus,
                benchmark: benchmark)
        case .appleSpeech:
            // Reaching here means preparation already succeeded, which only happens on the macOS 26
            // SDK path. On older SDKs `AppleSpeechModelPreparation.prepare` reports the provider
            // unavailable, so the start is rejected before construction and this case is unreachable.
            #if compiler(>=6.2) && canImport(FoundationModels) && canImport(Speech) && !JARVIS_FORCE_APPLE_SPEECH_FALLBACK
            if #available(macOS 26.0, *), let appleSpeechLocale {
                AppleSpeechTranscriber(
                    locale: appleSpeechLocale,
                    speaker: speaker,
                    transcript: transcript,
                    clock: clock,
                    sessionStart: sessionStart,
                    silenceTimeout: config.silenceTimeoutSeconds,
                    silenceMaxInterval: config.silenceMaxIntervalSeconds,
                    silenceIdleCutoff: speaker == .me
                        ? config.silenceIdleCutoffSeconds
                        : .infinity,
                    transcriptBatchingWindow: config.transcriptBatchingWindowSeconds,
                    maxBufferedAudioSeconds: config.maxBufferedAudioSeconds,
                    benchmark: benchmark)
            } else {
                preconditionFailure("Apple Speech must be prepared before constructing its session")
            }
            #else
            preconditionFailure("Apple Speech is unavailable in this build")
            #endif
        }
    }
}
