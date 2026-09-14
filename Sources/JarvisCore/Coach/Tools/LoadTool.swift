import Foundation

extension CoachCapabilities {
    public static let loadToolName = "load_tool"

    /// Built per Start from the deferred tools actually present; see `loaderParametersJSON`.
    static func loadTool(catalogNames: [String]) -> ToolDef {
        ToolDef(
            name: loadToolName,
            description: "Load a tool listed under 'Tools you can load'. Returns its "
                + "arguments schema and usage guidance. Call it once per tool, before that tool's "
                + "first use.",
            parametersJSON: loaderParametersJSON(catalogNames: catalogNames))
    }
}

// The tool results the harness sends for a load.
extension JarvisPrompts.Coach {
    static func loadToolResult(_ tool: ToolDef) -> String {
        "Loaded \(tool.name).\nArguments JSON Schema: \(tool.parametersJSON)\n\n\(tool.guidance)"
    }

    static func loadToolAlreadyLoaded(_ name: String) -> String {
        "\(name) is already loaded; its schema and guidance are earlier in this conversation. "
            + "Do not load it again."
    }

    /// Answers both an unknown load name and a call to a tool this session does not offer. The
    /// model is told plainly rather than failing the attempt: on a text protocol it can emit
    /// any name at all, and a refusal it can read is what stops it repeating the call.
    static func toolUnavailable(_ name: String) -> String {
        "No tool named \(name) is available."
    }
}
