import Foundation
import JarvisCore
@preconcurrency import Speech

/// Installs and reserves the selected locale before a new Apple Speech pipeline replaces a running
/// session. The configured module identity is disposable; `AssetInventory` manages shared system
/// assets by module configuration and automatically reserves a locale when installation needs it.
@available(macOS 26.0, *)
enum AppleSpeechModelPreparation {
    enum Failure: Error {
        case unavailable
        case localeUnsupported
    }

    static func prepare(localeIdentifier: String) async throws -> Locale {
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
    }
}
