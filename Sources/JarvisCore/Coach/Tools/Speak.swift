import Foundation

/// The one name every surface matches a `speak` call by. The definition is built per session, so
/// nothing outside `CoachCapabilities` may reach for a global to learn what the tool is called.
public let speakToolName = "speak"

/// Built once per session by `CoachCapabilities.compose`.
///
/// `detail` exists only when the Overlay Box can show it, so no session declares a field the box
/// would throw away. The session's one capability set both describes the tool in the prompt and
/// declares it on every request, so a session can never describe one schema and send another
/// (#273). `detail` is nullable rather than absent because that is what makes a field optional
/// under strict Structured Outputs.
///
/// What belongs in `detail` is prompt text's decision, not the runtime's: the guidance here says
/// when to write one at all, and a loaded skill says what its own domain puts there.
public func speakTool(detailEnabled: Bool) -> ToolDef {
    ToolDef(
        name: speakToolName,
        description: "Show a coaching reply: up to 3 short overlay lines, one idea each, under 12 "
            + "words. Call only when a reply is useful."
            + (detailEnabled
                ? " Put a code block, a diagram, or a short explanation in detail as Markdown; "
                    + "null for an ordinary hint."
                : ""),
        // Laid out one field per line for reading. Line breaks and the indentation after them are
        // stripped, so every brain receives the compact form; no JSON string here contains a line
        // break.
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

/// The system prompt's tip style. It governs `speak` and nothing else, and `speak` is always on, so
/// the action policy's cross-reference to it can never dangle.
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
    that builds on it. When "them" asks for a better approach and "me" has not offered one, name
    that approach and why it is better, not a question about it.
    Give a full solution only when "me" explicitly asks for it. The shape of an approach is not a
    full solution.

    Name things with the words already in front of "me" — on the captured screen, or in what
    either speaker said. Do not use an unfamiliar term as if it were shared. When a new term or
    symbol genuinely is the right one, gloss it on first use ("1<<h, that is 2 to the power h");
    accuracy outranks brevity.
    """

/// Present only when the Overlay Box can show a detail. It says what `detail` is for and what keeps
/// it null; a loaded skill adds the rules for its own domain's blocks.
///
/// The need for an explanation is read from the conversation, never from a request: mid-interview
/// "me" is talking to the interviewer and cannot stop to ask Jarvis why. A live session waited for
/// that request while the interviewer asked for a better approach, and the user got a one-line
/// recurrence they could copy but not follow. Detail is read in seconds under stress, so it stays
/// short and plain.
private let detailGuidance = """
    # Detail
    The lines are the coaching. For an ordinary hint, say what the user needs there and leave
    detail null.
    detail is Markdown shown under the hint in the persistent box. Use it for what a line cannot
    hold: a code block or a diagram a loaded skill asked for, or a short explanation when "me"
    needs an idea they do not have yet.
    "me" is in a live conversation and cannot stop to ask you why, so read that need from the
    conversation: "them" pushes past what "me" gave, such as asking for a better approach, and "me"
    has no answer; or "me" asks for time, stops mid-sentence, or restates something wrongly. A new
    question or quiet alone does not show it, and you hear transcripts, not tone.
    "me" reads detail in seconds, under pressure. Keep it to what the gap needs, in plain words and
    a few short lines: the key idea in one sentence, a tiny example on the case already in play
    when it helps, and any block a loaded skill asks for. No headings, background, or alternatives.
    If an earlier explanation didn't land, use a simpler framing or a smaller example instead of
    repeating it.
    Never invent personal experience or screen details you haven't seen.
    """

// The tool result the harness sends once a tip is on screen. It names anything the box could not
// show, so the model treats a dropped block as a fact rather than assuming it landed.
extension JarvisPrompts.Coach {
    static func tipShown(dropped: [String] = []) -> String {
        dropped.isEmpty ? "shown to the user" : "shown to the user; " + dropped.joined(separator: "; ")
    }
}
