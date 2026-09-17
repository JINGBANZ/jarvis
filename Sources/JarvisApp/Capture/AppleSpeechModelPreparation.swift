import Foundation
import JarvisCore
#if compiler(>=6.2) && canImport(FoundationModels) && canImport(Speech) && !JARVIS_FORCE_APPLE_SPEECH_FALLBACK
@preconcurrency import Speech
#endif

/// `SpeechTranscriber` runs on-device, so this path deliberately skips speech-recognition
/// authorization, which applies only to server-side recognition.
///
/// The type exists on every build so the app links. `FoundationModels` marks the macOS 26 SDK
/// because `Speech` itself exists in older SDKs; there `prepare` throws `.unavailable`.
@available(macOS 26.0, *)
enum AppleSpeechModelPreparation {
    enum Failure: Error {
        case unavailable
        case localeUnsupported
    }

    static func prepare(localeIdentifier: String) async throws -> Locale {
        #if compiler(>=6.2) && canImport(FoundationModels) && canImport(Speech) && !JARVIS_FORCE_APPLE_SPEECH_FALLBACK
        guard SpeechTranscriber.isAvailable else {
            throw Failure.unavailable
        }
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            throw Failure.localeUnsupported
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            jlog("Jarvis Apple Speech: downloading the \(locale.identifier) model.")
            try await request.downloadAndInstall()
            jlog("Jarvis Apple Speech: model download finished.")
        }
        return locale
        #else
        throw Failure.unavailable
        #endif
    }
}
