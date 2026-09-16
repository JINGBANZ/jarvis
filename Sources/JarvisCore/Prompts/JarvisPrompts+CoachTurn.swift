import Foundation

// The messages the harness adds to a coaching conversation as it goes: new speech, the trigger that
// starts a turn, the summary that replaces condensed history, and the answers to a reply the runner
// could not run as sent. Tool results live with their tool in `Coach/Tools/`.
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

    // Each press says what the user wants, once. How to answer it is the speak guidance's job, and
    // the domain rules are the loaded skill's, so a trigger that restated them would be a third
    // copy to keep in step.
    static func manualExplanationTrigger(timestamp: String) -> String {
        "[\(timestamp)] The user pressed Explain more. They don't follow the question, an earlier "
            + "hint, or the approach. Explain that gap in detail, with a short summary in lines."
    }

    /// The skill a Show code press preloads. Its body carries the code-block rules, so the press
    /// still answers in one round trip.
    static let showCodeSkillName = "coding"

    static func manualCodeTrigger(timestamp: String) -> String {
        "[\(timestamp)] The user pressed Show code. Add the next small code block for their current "
            + "sticking point to detail, at most \(CodeBlock.lineLimit) lines."
    }

    /// The answer to a press that replied in plain text. It names `detail` only where the session
    /// declared one, so a boxless session is never told about a field it does not have.
    static func replyMustCallSpeak(detailEnabled: Bool) -> String {
        "Plain text is not an answer here. Call the speak tool: the short lines are shown to the "
            + (detailEnabled ? "user, and anything longer goes in detail." : "user.")
    }

    static func condensedHistory(_ summary: String) -> String {
        "[session so far, condensed — earlier turns were summarized]\n\(summary)"
    }

    static func notPermittedOnShortcut(_ name: String) -> String {
        "\(name) is not available on a shortcut press. Give the hint with speak."
    }

    static func argumentsRejected(_ tool: ToolDef) -> String {
        "The arguments for \(tool.name) did not match its schema and were not run. "
            + "Call it again with arguments that match this JSON Schema: \(tool.parametersJSON)"
    }

    static let extraCallNotExecuted =
        "Only one action runs per response. This call was not executed; call it again next turn if it is still needed."
}
