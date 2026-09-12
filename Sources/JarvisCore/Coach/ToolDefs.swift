import Foundation

// NB: schemas set additionalProperties:false and mark every key required — the requirements for the
// `strict:true` Structured Outputs that OpenAIBrainClient sends on each tool. The empty-object schema
// below is valid under strict (no properties, none required).
public let captureScreenTool = ToolDef(
    name: "capture_screen",
    description: JarvisPrompts.Coach.ToolDescription.captureScreen,
    parametersJSON: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#
)

/// One schema on every brain and in every session. `mermaid` is nullable rather than absent because
/// that is what makes a field optional under strict Structured Outputs, and because a second speak
/// variant is what let the tool array a local-agent process was warmed with drift from the one the
/// coach loop later sent (#273). Whether a supplied graph is rendered is a runtime decision.
public let speakTool = ToolDef(
    name: "speak",
    description: JarvisPrompts.Coach.ToolDescription.speak,
    parametersJSON: #"{"type":"object","properties":{"lines":{"type":"array","items":{"type":"string"}},"mermaid":{"type":["string","null"],"description":"A small Mermaid graph for a private architecture sketch. Null unless the coaching guidance for this session asks for a diagram."},"explanation":{"type":["string","null"]},"codeSnippet":{"type":["object","null"],"properties":{"language":{"type":"string"},"placement":{"type":"string"},"code":{"type":"string"},"highlightedLines":{"type":"array","items":{"type":"integer"}}},"required":["language","placement","code","highlightedLines"],"additionalProperties":false}},"required":["lines","mermaid","explanation","codeSnippet"],"additionalProperties":false}"#,
    guidance: JarvisPrompts.Coach.ToolGuidance.speak
)

public let staySilentTool = ToolDef(
    name: "stay_silent",
    description: JarvisPrompts.Coach.ToolDescription.staySilent,
    parametersJSON: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#
)

/// The three coaching actions every session offers. `CoachCapabilities.compose` builds the session's
/// full set from these plus whatever the user's configuration adds.
public let coachTools: [ToolDef] = [captureScreenTool, speakTool, staySilentTool]

/// In the catalog only when the session has prep-material sources configured at Start. The search
/// port itself lands later, after indexing.
public let searchPrepNotesTool = ToolDef(
    name: "search_prep_notes",
    description: JarvisPrompts.Coach.ToolDescription.searchPrepNotes,
    parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#,
    guidance: JarvisPrompts.Coach.ToolGuidance.searchPrepNotes
)
