import Foundation

/// The service that turns the captured microphone and system-audio streams into text.
///
/// This choice is independent of `BrainProvider`: transcription supplies the conversation, while
/// the brain decides how to coach from it.
public enum TranscriptionProvider: String, CaseIterable, Codable, Sendable {
    case openAI = "openai"
    case appleSpeech = "apple-speech"
    case gemini = "gemini"

    public var displayName: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .appleSpeech:
            "Apple Speech"
        case .gemini:
            "Gemini"
        }
    }

    /// The credential this provider needs to transcribe, if any. Apple Speech is on-device.
    /// `public` because `AppDelegate` (JarvisApp) selects the transcription key from it.
    public var ownCredential: Credential? {
        switch self {
        case .openAI: .openAIAPIKey
        case .gemini: .geminiAPIKey
        case .appleSpeech: nil
        }
    }

    /// Every credential a Start needs: this provider's own, plus OpenAI's when any authorized brain
    /// target is OpenAI. Both halves can require a key independently — Gemini ears with an OpenAI
    /// brain needs two — which a single Bool could not express.
    public func requiredCredentials(for brainRoute: BrainRoute?) -> Set<Credential> {
        var required = Set(ownCredential.map { [$0] } ?? [])
        if brainRoute?.targets.contains(where: { $0.provider == .openAI }) == true {
            required.insert(.openAIAPIKey)
        }
        return required
    }
}
