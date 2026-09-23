import Foundation

extension CoachCapabilities {
    public static let loadToolName = "load_tool"

    static func loadTool(catalogNames: [String]) -> ToolDef {
        ToolDef(
            name: loadToolName,
            description: "Load a tool listed under 'Tools you can load'. Returns its "
                + "arguments schema and usage guidance. Call it once per tool, before that tool's "
                + "first use.",
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
