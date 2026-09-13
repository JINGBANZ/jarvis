import Foundation

public let staySilentTool = ToolDef(
    name: "stay_silent",
    description: "End this turn without speaking. Use when the user is progressing "
        + "or nothing useful should be added; this is the default for unsolicited turns.",
    parametersJSON: #"{"type":"object","properties":{"screenMemory":{"type":["object","null"],"properties":{"newQuestion":{"type":"boolean"},"obsoleteObservationIDs":{"type":"array","items":{"type":"integer"}}},"required":["newQuestion","obsoleteObservationIDs"],"additionalProperties":false}},"required":["screenMemory"],"additionalProperties":false}"#
)
