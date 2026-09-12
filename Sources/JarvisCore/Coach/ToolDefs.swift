import Foundation

// NB: schemas set additionalProperties:false and mark every key required — the requirements for the
// `strict:true` Structured Outputs that OpenAIBrainClient sends on each tool. The empty-object schema
// below is valid under strict (no properties, none required).
public let captureScreenTool = ToolDef(
    name: "capture_screen",
    description: JarvisPrompts.Coach.ToolDescription.captureScreen,
    parametersJSON: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#
)

public let speakTool = ToolDef(
    name: "speak",
    description: JarvisPrompts.Coach.ToolDescription.speak,
    parametersJSON: #"{"type":"object","properties":{"lines":{"type":"array","items":{"type":"string"}},"explanation":{"type":["string","null"]},"codeSnippet":{"type":["object","null"],"properties":{"language":{"type":"string"},"placement":{"type":"string"},"code":{"type":"string"},"highlightedLines":{"type":"array","items":{"type":"integer"}}},"required":["language","placement","code","highlightedLines"],"additionalProperties":false}},"required":["lines","explanation","codeSnippet"],"additionalProperties":false}"#
)

public let staySilentTool = ToolDef(
    name: "stay_silent",
    description: JarvisPrompts.Coach.ToolDescription.staySilent,
    parametersJSON: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#
)

public let coachTools: [ToolDef] = [captureScreenTool, speakTool, staySilentTool]

/// Offered only when the session has prep-material sources configured at Start, which is decided
/// once by `sessionCoachTools` below. The search port itself lands later, after indexing.
public let searchPrepNotesTool = ToolDef(
    name: "search_prep_notes",
    description: JarvisPrompts.Coach.ToolDescription.searchPrepNotes,
    parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#
)

/// System-design sessions can attach a visual hint without changing the terminal speak action
/// (including force(speak) for the manual shortcut). Null means an ordinary text hint.
public let systemDesignSpeakTool = ToolDef(
    name: speakTool.name,
    description: JarvisPrompts.Coach.ToolDescription.speak,
    parametersJSON: #"{"type":"object","properties":{"lines":{"type":"array","items":{"type":"string"}},"explanation":{"type":["string","null"]},"mermaid":{"type":["string","null"]},"codeSnippet":{"type":["object","null"],"properties":{"language":{"type":"string"},"placement":{"type":"string"},"code":{"type":"string"},"highlightedLines":{"type":"array","items":{"type":"integer"}}},"required":["language","placement","code","highlightedLines"],"additionalProperties":false}},"required":["lines","mermaid","explanation","codeSnippet"],"additionalProperties":false}"#
)

/// The tool set one session offers, resolved once at Start and then fixed for the session's life.
///
/// Fixed rather than per-attempt because a local-agent target bakes each tool's `parametersJSON`
/// into the instructions its process is warmed with, and re-checks the composed string on every turn
/// (`CLIBrainClient.prepareTurn`). A set that grew or changed shape mid-session was rejected there,
/// failing every remaining attempt on that target until the route exhausted — see #273. So both the
/// app's brain composition and the coach loop resolve their tools here, from inputs known at Start.
///
/// `prepMaterial` is therefore "prep sources are configured", not "the index has finished building":
/// indexing runs off the Start path deliberately, so the port arrives after the first attempts. A
/// search that lands before it returns no matches rather than changing what the session offers.
public func sessionCoachTools(interviewFormat: InterviewFormat?, prepMaterial: Bool) -> [ToolDef] {
    let base = coachTools.map {
        interviewFormat == .systemDesign && $0.name == speakTool.name ? systemDesignSpeakTool : $0
    }
    return prepMaterial ? base + [searchPrepNotesTool] : base
}
