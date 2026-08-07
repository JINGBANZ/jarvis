import Foundation

extension JarvisPrompts {
    public enum Transcription {
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
