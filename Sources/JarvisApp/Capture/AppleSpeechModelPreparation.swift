import Foundation
import JarvisCore
#if compiler(>=6.2) && canImport(FoundationModels) && canImport(Speech) && !JARVIS_FORCE_APPLE_SPEECH_FALLBACK
@preconcurrency import Speech
#endif

/// Installs and reserves the selected locale before a new Apple Speech pipeline replaces a running
/// session. The configured module identity is disposable; `AssetInventory` manages shared system
/// assets by module configuration and automatically reserves a locale when installation needs it.
/// `SpeechTranscriber` runs entirely on-device; Apple's speech-recognition usage key applies to APIs
/// that send speech data to its servers, so this path intentionally avoids legacy authorization.
///
/// The type and its `prepare` signature exist on every build so the app shell (`AppDelegate`) links
/// unchanged; only the macOS 26 Speech body is compiled when the compiler and active SDK expose it.
/// `FoundationModels` is an SDK marker because it first ships alongside these Speech APIs, while the
/// `Speech` module itself also exists in older SDKs. On older SDKs `prepare` reports Apple Speech
/// unavailable through the same typed failure so a persisted `.appleSpeech` selection degrades
/// cleanly instead of constructing a session.
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
