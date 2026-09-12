import Foundation

/// What one coaching session can do: the tools it offers, hot or deferred, resolved once at Start.
///
/// One value, read by everything. A local-agent target bakes each tool's `parametersJSON` and the
/// system prompt describing it into the instructions its process is warmed with, and re-checks the
/// composed string on every turn (`CLIBrainClient.prepareTurn`). A set that grew or changed shape
/// mid-session was rejected there, failing every remaining attempt on that target until the route
/// exhausted — see #273. So the app's brain composition and the coach loop resolve from this one
/// value, computed at Start from inputs known then.
///
/// `prepSourcesConfigured` is therefore "prep sources are configured", not "the index has finished
/// building": indexing runs off the Start path deliberately, so the port arrives after the first
/// attempts. Availability is a runtime result, never a Start-time omission.
public struct CoachCapabilities: Sendable, Equatable {
    /// Hot and deferred tools, in prompt order. Fixed for the session.
    public let tools: [ToolDef]

    /// Offered with full schema and guidance from the first request.
    public var hotTools: [ToolDef] { tools.filter { !$0.deferLoading } }
    /// In the catalog by name and description only, until the model loads one.
    public var deferredTools: [ToolDef] { tools.filter(\.deferLoading) }
    public var catalogNames: [String] { deferredTools.map(\.name) }

    public static let loadToolName = "load_tool"

    /// Names the user cannot switch off: Jarvis cannot start without screen capture, a turn cannot
    /// end without speak or stay silent, and the loader is included so a hand-edited plist cannot
    /// remove it while deferred tools remain in the catalog. The loader needs no switch of its own:
    /// it disappears when nothing is left to load.
    public static let fixedToolNames: Set<String> =
        [captureScreenTool.name, speakTool.name, staySilentTool.name, loadToolName]

    /// Order: capture_screen, speak, stay_silent, load_tool, then the deferred tools.
    /// `search_prep_notes` is present only when `prepSourcesConfigured` and the user has not
    /// switched it off. Names in `disabledTools` that match nothing, or that name a fixed tool, are
    /// ignored.
    public static func compose(disabledTools: Set<String>,
                               prepSourcesConfigured: Bool) -> CoachCapabilities {
        let disabled = disabledTools.subtracting(fixedToolNames)
        let extras = (prepSourcesConfigured ? [searchPrepNotesTool] : [])
            .filter { !disabled.contains($0.name) }
        let deferred = extras.filter(\.deferLoading)
        return CoachCapabilities(
            tools: coachTools
                + (deferred.isEmpty ? [] : [loadTool(catalogNames: deferred.map(\.name))])
                + extras)
    }

    /// Built per Start rather than as a global: the `name` schema is an enum of the deferred names
    /// actually present, so on a schema-enforcing provider a misspelled name cannot be emitted at
    /// all. The list is fixed at Start, which keeps a CLI target's baked instructions constant.
    private static func loadTool(catalogNames: [String]) -> ToolDef {
        let names = catalogNames
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            .joined(separator: ",")
        return ToolDef(
            name: loadToolName,
            description: JarvisPrompts.Coach.ToolDescription.loadTool,
            parametersJSON: #"{"type":"object","properties":{"name":{"type":"string","enum":["#
                + names
                + #"]}},"required":["name"],"additionalProperties":false}"#)
    }

    /// The three coaching actions and nothing else: what a session composed without configuration
    /// offers, and the default for tests.
    public static let `default` = compose(disabledTools: [], prepSourcesConfigured: false)

    /// What the model may call right now: every hot tool, plus the deferred tools already loaded.
    public func callable(loaded: Set<String>) -> [ToolDef] {
        tools.filter { !$0.deferLoading || loaded.contains($0.name) }
    }

    public func tool(named name: String) -> ToolDef? {
        tools.first { $0.name == name }
    }
}
