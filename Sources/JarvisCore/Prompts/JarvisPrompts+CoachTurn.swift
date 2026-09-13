import Foundation

// The messages the harness adds to a coaching conversation as it goes: new speech, the trigger that
// starts a turn, and the summary that replaces condensed history. Tool results live with their tool
// in `Coach/Tools/`.
extension JarvisPrompts.Coach {
    static func newSpeech(_ text: String) -> String {
        "New since last turn:\n\(text)"
    }

    static func silenceTrigger(timestamp: String, duration: String) -> String {
        "[\(timestamp)] (no speech for \(duration))"
    }

    static func manualHintTrigger(timestamp: String) -> String {
        "[\(timestamp)] The user pressed the hint shortcut. They want your single most useful "
            + "hint about what's on their screen right now — answer using the attached screenshot "
            + "and the recent transcript."
    }

    static func manualExplanationTrigger(timestamp: String) -> String {
        "[\(timestamp)] The user pressed Explain more. They do not understand the question, "
            + "an earlier hint, or the overall approach. Use the available session history, "
            + "newest speech, and attached screen to identify the gap. Explain why it works in "
            + "plain language with a small example and a concrete starting point. Put the fuller "
            + "explanation in explanation and a short standalone summary in lines. If already "
            + "explained, change the framing or simplify; do not just repeat the last hint."
    }

    static func manualCodeTrigger(timestamp: String) -> String {
        "[\(timestamp)] The user pressed the Show code shortcut for THIS request. Show the next small "
            + "logical snippet for their current sticking point, aligned with their existing code. "
            + "Use codeSnippet with language, placement, raw code, and highlightedLines for local corrections. "
            + "Keep lines as a short placement or correction hint. Do not show the full solution. "
            + "If no current code is visible, provide the first component using known problem context. "
            + "If the overall approach is invalid, give its corrective hint and leave codeSnippet null."
    }

    static func condensedHistory(_ summary: String) -> String {
        "[session so far, condensed — earlier turns were summarized]\n\(summary)"
    }
}
