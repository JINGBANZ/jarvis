import Foundation

/// One schema on every brain and in every session. `mermaid` is nullable rather than absent because
/// that is what makes a field optional under strict Structured Outputs, and because a second speak
/// variant is what let the tool array a local-agent process was warmed with drift from the one the
/// coach loop later sent (#273). When a graph belongs on a tip is prompt text's decision, not the
/// runtime's: any graph the renderer can parse reaches the overlay.
///
/// The guidance is the system prompt's tip style. It governs `speak` and nothing else, and `speak`
/// is always on, so the action policy's cross-reference to it can never dangle.
public let speakTool = ToolDef(
    name: "speak",
    description: "Show a coaching reply as up to 3 short standalone overlay lines. "
        + "Use one idea per line, aim under 12 words, and keep code on one line. Call only "
        + "when a reply or tip is useful. Put fuller plain-language clarification in explanation; "
        + "use null for ordinary hints. The explanation appears only in the persistent box. "
        + "Where your instructions call for code, put the component implementing this hint "
        + "in codeSnippet; otherwise, and for conceptual guidance, use null.",
    // Laid out one field per line for reading. Line breaks and the indentation after them are
    // stripped, so every brain receives the compact form; no JSON string here contains a line break.
    parametersJSON: #"""
        {"type":"object","properties":{
            "lines":{"type":"array","items":{"type":"string"}},
            "mermaid":{"type":["string","null"],"description":"A small Mermaid graph for a private architecture sketch. Null unless a loaded skill asks for a diagram."},
            "explanation":{"type":["string","null"]},
            "codeSnippet":{"type":["object","null"],"properties":{
                "language":{"type":"string"},
                "placement":{"type":"string"},
                "code":{"type":"string"},
                "highlightedLines":{"type":"array","items":{"type":"integer"}}
            },"required":["language","placement","code","highlightedLines"],"additionalProperties":false}
        },"required":["lines","mermaid","explanation","codeSnippet"],"additionalProperties":false}
        """#.replacingOccurrences(of: #"\n\s*"#, with: "", options: .regularExpression),
    guidance: """
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

        Set mermaid to null. Attach a graph only when a loaded skill has told you to, and only
        for the case it describes.
        """
)

// The tool result the harness sends once a tip is on screen.
extension JarvisPrompts.Coach {
    static let tipShown = "shown to the user"
}
