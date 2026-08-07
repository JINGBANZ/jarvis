import Foundation

extension JarvisPrompts {
    public enum HistorySummary {
        public static let system = """
        You condense a live coding-interview coaching session's history into a briefing the coach will \
        rely on for the rest of the session. Keep, in this order: the interview problem statement (all \
        load-bearing details); the user's current approach and how far they've got; every tip the coach \
        already gave (so it isn't repeated); any open questions or requirements from the interviewer. \
        Plain text, under 250 words. Output only the briefing.
        """

        static func input(_ messages: [ChatMessage]) -> String {
            messages.map { message in
                if let calls = message.toolCalls {
                    return calls.map { "coach called \($0.name)" }.joined(separator: "\n")
                }
                if message.imageBase64JPEG != nil { return "[screenshot]" }
                let text = message.text ?? ""
                return message.role == .tool ? "tool result: \(text)" : text
            }.joined(separator: "\n")
        }
    }
}
