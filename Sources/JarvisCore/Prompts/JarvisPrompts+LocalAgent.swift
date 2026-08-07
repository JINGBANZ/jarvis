import Foundation

extension JarvisPrompts {
    enum LocalAgent {
        static let codexDirectResponse = """
            Answer this decision request immediately without inspecting files, running commands,
            browsing, planning, delegating, or invoking any Codex built-in tool. The capture_screen,
            speak, and stay_silent names below are an output JSON protocol, not callable Codex tools.
            """

        static func roleBlock(_ role: String, text: String) -> String {
            "[\(role)]\n\(text)"
        }

        static func assistantToolCall(name: String, argumentsJSON: String) -> String {
            roleBlock("assistant", text: "{\"tool\":\"\(name)\",\"arguments\":\(argumentsJSON)}")
        }

        static func conversationHeading(isFirstTurn: Bool) -> String {
            isFirstTurn ? "## Conversation" : "## New input"
        }

        static let screenshotPlaceholder = roleBlock("user", text: "(screenshot below)")

        static func answerTrailer(forcedToolName: String?) -> String {
            var trailer = "Answer now, following the tool protocol."
            if let forcedToolName {
                trailer += " You MUST call the `\(forcedToolName)` tool this turn."
            }
            return trailer
        }

        static func toolProtocol(tools: [ToolDef], toolChoice: ToolChoice) -> String {
            var lines = [
                "## Tool protocol",
                "",
                "You are the decision engine inside an automated harness — your reply is parsed "
                    + "by a program, not read by a person. These are your tools:",
            ]
            for tool in tools {
                lines.append("- \(tool.name) — \(tool.description)")
                lines.append("  arguments JSON Schema: \(tool.parametersJSON)")
            }
            lines.append("")
            lines.append(
                "End your reply with a single line containing ONLY this JSON object (no code "
                    + "fence, nothing after it): {\"tool\":\"<tool name>\",\"arguments\":{…}}. "
                    + "Use {} for a tool with no arguments."
            )
            switch toolChoice {
            case .required, .force:
                // `.force` stays byte-identical to `.required` here so one forced hint does not
                // rewrite the cacheable system prefix. Its tool name belongs in the turn trailer.
                lines.append(
                    "You MUST pick exactly one tool this turn — the JSON object is your entire answer."
                )
            case .auto:
                lines.append("If no tool fits, reply with plain text instead of the JSON object.")
            }
            return lines.joined(separator: "\n")
        }
    }
}
