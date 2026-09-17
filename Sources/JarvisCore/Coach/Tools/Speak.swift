import Foundation

public let speakToolName = "speak"

public func speakTool(detailEnabled: Bool) -> ToolDef {
    ToolDef(
        name: speakToolName,
        description: "Show a coaching reply: up to 3 short overlay lines, one idea each, under 12 "
            + "words. Call only when a reply is useful."
            + (detailEnabled
                ? " Put a code block or a diagram in detail as Markdown; null for an ordinary hint."
                : ""),
        // Line breaks and the indentation after them are stripped, so no JSON string here may
        // contain a line break.
        parametersJSON: (detailEnabled
            ? #"""
            {"type":"object","properties":{
                "lines":{"type":"array","items":{"type":"string"}},
                "detail":{"type":["string","null"],"description":"Markdown shown under the hint in the box. Null for an ordinary hint."}
            },"required":["lines","detail"],"additionalProperties":false}
            """#
            : #"""
            {"type":"object","properties":{
                "lines":{"type":"array","items":{"type":"string"}}
            },"required":["lines"],"additionalProperties":false}
            """#).replacingOccurrences(of: #"\n\s*"#, with: "", options: .regularExpression),
        guidance: tipStyle + (detailEnabled ? "\n\n" + detailGuidance : ""))
}

private let tipStyle = """
    # Tip style
    Lead with the most useful point. Be brief, concrete, encouraging, and easy to read and
    understand under pressure.

    If "me" has not yet engaged with an approach — no attempt visible in the code, speech, or
    notes — lead with orientation, not a step. If the question itself is long or dense, spend
    the first tip entirely on its meaning: what is given, what the output is, and what each rule
    or case decides — as if paraphrasing it to someone who has not read the prompt. Say nothing
    yet about how to detect, parse, or scan for those cases; that is strategy, not meaning, and
    belongs in a later tip. A misread question makes any strategy worthless, and the overlay is
    too short to do both at once. Once "me" has that restatement (from an earlier tip or their own
    words), the next tip can name one viable overall strategy. A "next step" means nothing without
    a plan to hang it on. Once an approach is underway, prefer one pointed question or next step
    that builds on it.
    Give a full solution only when "me" explicitly asks for it.

    Name things with the words already in front of "me" — on the captured screen, or in what
    either speaker said. Do not use an unfamiliar term as if it were shared. When a new term or
    symbol genuinely is the right one, gloss it on first use ("1<<h, that is 2 to the power h");
    accuracy outranks brevity.
    """

private let detailGuidance = """
    # Detail
    The lines are the coaching. Say what the user needs there, including a short explanation, and
    leave detail null.
    detail is Markdown shown under the hint in the persistent box. Use it for what a line cannot
    hold: a code block or a diagram a loaded skill asked for. Write paragraphs there only when the
    user asks you to explain, or is clearly lost: they ask why, they restate something wrongly, or
    they say they can't follow earlier advice. Silence or unchanged work is not confusion, and you
    hear transcripts, not tone.
    When you do explain, keep it to what the gap needs: why it works, a tiny example when it helps,
    and one next action. If an earlier explanation didn't land, simplify or use a smaller example
    instead of repeating it.
    Never invent personal experience or screen details you haven't seen.
    """

extension JarvisPrompts.Coach {
    static func tipShown(dropped: [String] = []) -> String {
        dropped.isEmpty ? "shown to the user" : "shown to the user; " + dropped.joined(separator: "; ")
    }
}
