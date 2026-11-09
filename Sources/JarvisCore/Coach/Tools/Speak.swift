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
        Answer the user's current request directly. Follow applicable loaded skills for delivery.
        Ground replies in the available evidence. Never invent personal experience or screen details.

        # Hint
        One direct, connected reply of at most 36 words. Lead with the most useful answer or advice.
        Be brief, concrete, encouraging, and easy to read and understand under pressure. Connect related
        sentences naturally; the overlay handles wrapping.

        The hint must make sense without detail. When giving advice, keep its brief rationale here. For
        unsolicited help, offer one useful cue or next move that builds on what the user is doing.

        Use words and names already established in the conversation or visible evidence. Do not treat
        unfamiliar terminology as shared knowledge. When introducing a necessary term or symbol, briefly
        explain it on first use—for example, “1<<h, that is 2 to the power h.” Accuracy takes priority over
        brevity.

        # Detail
        Optional Markdown displayed below the hint. Include it for requested content that cannot fit
        in the hint, supporting content required by an applicable loaded skill, or a warranted explanation.
        Otherwise use null.

        For longer requested content, put a concise answer or summary in hint and the requested content
        here, following the requested format. For skill-required content, follow that skill’s conditions
        and presentation rules; an explanation request is not required.

        An explanation is warranted when the user asks for one or shows a specific understanding gap:
        they ask why, restate something incorrectly, or say they cannot follow. Silence or unchanged work
        alone does not establish confusion.

        Explain what the gap needs: why it works, a tiny example when useful, and one next action. If an
        earlier explanation did not help, simplify or use a smaller example instead of repeating it.
        """
)

extension JarvisPrompts.Coach {
    static func tipShown(at completedAt: TimeInterval, firstShownAt: TimeInterval? = nil,
                         dropped: [String] = []) -> String {
        let complete = RollingTranscript.stamp(completedAt)
        let receipt: String
        if let firstShownAt {
            receipt = "Shown to user from \(RollingTranscript.stamp(firstShownAt)); complete at \(complete)."
        } else {
            receipt = "Shown to user at \(complete)."
        }
        return dropped.isEmpty ? receipt : receipt + " " + dropped.joined(separator: "; ")
    }
}
