import Foundation

extension JarvisPrompts {
    public enum Transcription {
        public static func context(
            for speaker: Speaker,
            languagePolicy: ConversationLanguagePolicy = .init()
        ) -> String {
            let context: String = switch speaker {
            case .me:
                "A live technical-interview conversation captured from the local user's microphone. "
                    + "This stream contains the user's speech and may include names, numbers, and "
                    + "technical terminology."
            case .them:
                "A live technical-interview conversation captured from Mac system audio. This "
                    + "stream contains other participants' speech and may include names, numbers, "
                    + "and technical terminology."
            }
            return context + " Transcribe only speech in: \(languagePolicy.displayNames). "
                + "Ignore speech in other languages; do not translate it. "
                + "Ignore music, singing, background noise and silence; do not invent speech."
        }
    }
}
