import Foundation

extension JarvisPrompts {
    public enum Transcription {
        /// Describe the capture source and discourage invented non-speech transcripts without restricting languages.
        public static func context(for speaker: Speaker) -> String {
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
            return context + " Ignore music, singing and background noise; "
                + "do not invent speech when no one is speaking."
        }
    }
}
