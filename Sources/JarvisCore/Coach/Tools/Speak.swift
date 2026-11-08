import Foundation

public let speakToolName = "speak"

public let speakTool = ToolDef(
    name: speakToolName,
    description: "Show one direct reply to the user in the private overlay. Keep hint within 36 words "
        + "total; detail is optional Markdown shown underneath, not an audio response.",
    parametersJSON: #"""
        {"type":"object","properties":{
            "hint":{"type":"string","description":"One brief, direct, connected reply; the overlay handles wrapping."},
            "detail":{"type":["string","null"],"description":"Markdown shown under the hint for requested content that cannot fit there, supporting content required by a loaded skill, or a warranted explanation; otherwise null."}
        },"required":["hint","detail"],"additionalProperties":false}
        """#.replacingOccurrences(of: #"\n\s*"#, with: "", options: .regularExpression),
    guidance: """
        # Reply style
        Lead with the most useful point. Use brief, concrete, connected sentences in familiar language.
        Answer the user's current request directly; follow loaded skills for task-specific delivery.
        For unsolicited help, offer one useful cue or next move that builds on what the user is doing.
        Use words and names already established in the conversation or visible evidence. Explain an
        unfamiliar term or symbol on first use when needed; accuracy takes priority over brevity.

        # Supporting detail
        The short hint must stand on its own, including its brief rationale. Use detail for requested
        content that cannot fit in the short hint, supporting content required by a loaded skill, or a
        warranted explanation; otherwise set it to null. Put a concise answer or summary in hint and
        the requested content in detail. Follow the user's requested format.
        An explanation is warranted when the user asks for one or shows a specific understanding gap:
        they ask why, restate something incorrectly, or say they cannot follow. Silence or unchanged
        work alone does not establish confusion.
        When explaining, address that gap with the necessary reason, a tiny example when useful, and
        one next action. If an earlier explanation did not help, simplify or change the example.
        Do not invent personal experience or screen details.
        """
)

extension JarvisPrompts.Coach {
    static func tipShown(dropped: [String] = []) -> String {
        dropped.isEmpty ? "shown to the user" : "shown to the user; " + dropped.joined(separator: "; ")
    }
}
