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
