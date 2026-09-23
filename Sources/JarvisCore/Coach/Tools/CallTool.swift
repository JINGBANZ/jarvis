import Foundation

extension CoachCapabilities {
    public static let callToolName = "call_tool"

    /// Always declared beside `load_tool`, so a loaded tool never joins the declared list and the
    /// list stays byte-identical for the session on every brain. `arguments` is JSON text: strict
    /// mode can express it, and every provider accepts a string.
    static func callTool(catalogNames: [String]) -> ToolDef {
        ToolDef(
            name: callToolName,
            description: "Call a tool you loaded with load_tool. Pass its name and, as arguments, "
                + "the JSON object text that matches the schema its load result gave you.",
            parametersJSON: callToolParametersJSON(catalogNames: catalogNames))
    }

    static func callToolParametersJSON(catalogNames: [String]) -> String {
        #"{"type":"object","properties":{"name":{"type":"string","enum":["#
            + catalogEnumValues(catalogNames)
            + #"]},"arguments":{"type":"string","description":"JSON object text matching the loaded tool's schema"}},"required":["name","arguments"],"additionalProperties":false}"#
    }
}
