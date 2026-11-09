import Foundation

extension CoachCapabilities {
    public static let callToolName = "call_tool"

    /// Always hot beside `load_tool`, so a loaded tool never joins the `tools` array and the
    /// array stays byte-identical for the session on every brain. `arguments` is JSON text: strict
    /// mode can express it, and every provider accepts a string.
    static func callTool(catalogNames: [String]) -> ToolDef {
        ToolDef(
            name: callToolName,
            description: "Invoke an additional tool previously loaded with load_tool. Pass its name and, "
                + "as arguments, the JSON object text matching the schema in its load result.",
            parametersJSON: callToolParametersJSON(catalogNames: catalogNames))
    }

    static func callToolParametersJSON(catalogNames: [String]) -> String {
        #"{"type":"object","properties":{"name":{"type":"string","enum":["#
            + catalogEnumValues(catalogNames)
            + #"]},"arguments":{"type":"string","description":"JSON object text matching the loaded tool's schema"}},"required":["name","arguments"],"additionalProperties":false}"#
    }
}
