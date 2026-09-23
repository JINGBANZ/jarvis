import Foundation

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

    // A press says only what the user wants; how to answer belongs to the speak guidance and
    // skills.
    static func manualExplanationTrigger(timestamp: String) -> String {
        "[\(timestamp)] The user pressed Explain more. They don't follow the question, an earlier "
            + "hint, or the approach. Explain that gap in detail, with a short summary in lines."
    }

    static let showCodeSkillName = "coding"

    static func manualCodeTrigger(timestamp: String) -> String {
        "[\(timestamp)] The user pressed Show code. Add the next small code block for their current "
            + "sticking point to detail, at most \(CodeBlock.lineLimit) lines."
    }

    static let replyMustCallSpeak = "Plain text is not an answer here. Call the speak tool: the short "
        + "lines are shown to the user, and anything longer goes in detail."

    static let sessionStateHeader = "Session state:"

    /// Restated on every attempt and never kept in history: after a brain switch a load result
    /// deep in replayed history is easy to miss, and one current line costs less than a reload.
    /// Nil when there is nothing to state.
    static func sessionState(loadedSkills: [String], loadedTools: [String], unloadedTools: [String]) -> String? {
        // Facts only: saying how to call a loaded tool reads as an invitation to call it again.
        let loaded = loadedSkills.map { "skill \($0)" } + loadedTools.map { "tool \($0)" }
        var parts: [String] = []
        if !loaded.isEmpty {
            parts.append("Already loaded, never load again: \(loaded.joined(separator: ", ")).")
        }
        if !unloadedTools.isEmpty {
            parts.append("Not loaded yet: \(unloadedTools.map { "tool \($0)" }.joined(separator: ", ")).")
        }
        return parts.isEmpty ? nil : "\(sessionStateHeader) " + parts.joined(separator: " ")
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

    static func rejected(_ rejection: CoachCapabilities.CallRejection) -> String {
        switch rejection {
        case .notCallableByName(let name):
            "\(name) is not callable by name. Call it through call_tool with name \"\(name)\" and "
                + "its arguments as JSON text."
        case .unavailable(let name): toolUnavailable(name)
        case .malformed(let tool): argumentsRejected(tool)
        }
    }

    static let extraCallNotExecuted =
        "Only one action runs per response. This call was not executed; call it again next turn if it is still needed."
}
