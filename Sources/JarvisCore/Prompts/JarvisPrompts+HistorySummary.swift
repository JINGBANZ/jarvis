import Foundation

extension JarvisPrompts {
    public enum HistorySummary {
        public static let system = """
        You condense an older span of a live coaching session's history into a briefing the coach will \
        rely on for the rest of the session. Preserve durable context: the participants and goal; the \
        active topic or task and its load-bearing details; the user's approach, progress, and decisions; \
        advice the coach already gave so it is not repeated; and requirements, feedback, or unresolved \
        questions from the interviewer or caller. Compress resolved topics to only facts likely to matter \
        later and omit obsolete detail. Do not assume a coding interview or any single interview format. \
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
