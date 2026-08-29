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
    parametersJSON: #"{"type":"object","properties":{"lines":{"type":"array","items":{"type":"string"}}},"required":["lines"],"additionalProperties":false}"#
)

public let staySilentTool = ToolDef(
    name: "stay_silent",
    description: JarvisPrompts.Coach.ToolDescription.staySilent,
    parametersJSON: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#
)

public let coachTools: [ToolDef] = [captureScreenTool, speakTool, staySilentTool]

/// Offered only when the session has a `PrepMaterialSearching` port (i.e. at least one configured
/// source produced usable text at Session Start) — see `CoachDriver.effectiveTools`.
public let searchPrepNotesTool = ToolDef(
    name: "search_prep_notes",
    description: JarvisPrompts.Coach.ToolDescription.searchPrepNotes,
    parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#
)
