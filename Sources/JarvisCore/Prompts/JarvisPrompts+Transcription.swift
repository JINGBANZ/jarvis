import Foundation

extension JarvisPrompts {
    public enum Transcription {
        public static func languageContext(_ languages: [TranscriptionLanguage]) -> String {
            let names = TranscriptionLanguage.canonicalizing(languages)
                .map(\.displayName).joined(separator: " and ")
            return "The conversation uses \(names), including switching languages within a sentence. "
                + "Names, numbers, and technical terminology may appear in either language."
        }

        public static func context(for speaker: Speaker) -> String {
            switch speaker {
            case .me:
                "A live technical-interview conversation captured from the local user's microphone. "
                    + "This stream contains the user's speech and may include names, numbers, and "
                    + "technical terminology."
            case .them:
                "A live technical-interview conversation captured from Mac system audio. This "
                    + "stream contains other participants' speech and may include names, numbers, "
                    + "and technical terminology."
            }
        }
    }
}
