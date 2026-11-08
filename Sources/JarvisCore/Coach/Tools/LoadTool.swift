import Foundation

extension CoachCapabilities {
    public static let loadToolName = "load_tool"

    static func loadTool(catalogNames: [String]) -> ToolDef {
        ToolDef(
            name: loadToolName,
            description: "Load the schema and usage guidance for one tool in Available additional tools. "
                + "Load each tool once per session before its first use, then use call_tool. "
                + "Earlier load results remain available in the conversation.",
            parametersJSON: loaderParametersJSON(catalogNames: catalogNames))
    }
}

extension JarvisPrompts.Coach {
    static func loadToolResult(_ tool: ToolDef) -> String {
        "Loaded \(tool.name). Call it through call_tool with name \"\(tool.name)\" and, as "
            + "arguments, JSON text matching this schema: \(tool.parametersJSON)\n\n\(tool.guidance)"
    }

    static func loadToolAlreadyLoaded(_ name: String) -> String {
        "\(name) is already loaded; its schema and guidance are earlier in this conversation. "
            + "Do not load it again."
    }

    static func toolUnavailable(_ name: String) -> String {
        "No tool named \(name) is available."
    }
}
