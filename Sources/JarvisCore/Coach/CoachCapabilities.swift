import Foundation

/// The three coaching actions every session offers. `CoachCapabilities.compose` builds the session's
/// full set from these plus whatever the user's configuration adds.
public let coachTools: [ToolDef] = [captureScreenTool, speakTool, staySilentTool]

/// What one coaching session can do: the tools it offers, hot or deferred, and the skills it can
/// load — resolved once at Start.
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

    /// The switched-on bundled skills, sorted by name. Each contributes one catalog line; its body
    /// reaches the model only as a `load_skill` result.
    public let skills: [Skill]

    public init(tools: [ToolDef], skills: [Skill] = []) {
        self.tools = tools
        self.skills = skills
    }

    /// Offered with full schema and guidance from the first request.
    public var hotTools: [ToolDef] { tools.filter { !$0.deferLoading } }
    /// In the catalog by name and description only, until the model loads one.
    public var deferredTools: [ToolDef] { tools.filter(\.deferLoading) }
    public var catalogNames: [String] { deferredTools.map(\.name) }

    /// Names the user cannot switch off: Jarvis cannot start without screen capture, a turn cannot
    /// end without speak or stay silent, and the loaders are included so a hand-edited plist cannot
    /// remove one while its catalog still has entries. A loader needs no switch of its own: it
    /// disappears when nothing is left for it to load.
    public static let fixedToolNames: Set<String> =
        [captureScreenTool.name, speakTool.name, staySilentTool.name, loadToolName, loadSkillName]

    /// Order: capture_screen, speak, stay_silent, load_tool, load_skill, then the deferred tools.
    /// `search_prep_notes` is present only when `prepSourcesConfigured` and the user has not
    /// switched it off. Names in `disabledTools` that match nothing, or that name a fixed tool, are
    /// ignored; so are names in `disabledSkills` that match no bundled skill.
    public static func compose(disabledTools: Set<String>,
                               disabledSkills: Set<String> = [],
                               prepSourcesConfigured: Bool,
                               skills: [Skill] = []) -> CoachCapabilities {
        let disabled = disabledTools.subtracting(fixedToolNames)
        let extras = (prepSourcesConfigured ? [searchPrepNotesTool] : [])
            .filter { !disabled.contains($0.name) }
        let deferred = extras.filter(\.deferLoading)
        let offeredSkills = skills
            .filter { !disabledSkills.contains($0.name) }
            .sorted { $0.name < $1.name }
        return CoachCapabilities(
            tools: coachTools
                + (deferred.isEmpty ? [] : [loadTool(catalogNames: deferred.map(\.name))])
                + (offeredSkills.isEmpty ? [] : [loadSkill(catalogNames: offeredSkills.map(\.name))])
                + extras,
            skills: offeredSkills)
    }

    /// The schema both loaders share. They are built per Start rather than as globals: the `name`
    /// schema is an enum of the catalog names actually present, so on a schema-enforcing provider a
    /// misspelled name cannot be emitted at all. Each list is fixed at Start, which keeps a CLI
    /// target's baked instructions constant.
    static func loaderParametersJSON(catalogNames: [String]) -> String {
        let names = catalogNames
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            .joined(separator: ",")
        return #"{"type":"object","properties":{"name":{"type":"string","enum":["#
            + names
            + #"]}},"required":["name"],"additionalProperties":false}"#
    }

    /// The three coaching actions and nothing else: what a session composed without configuration
    /// offers, and the default for tests.
    public static let `default` = compose(disabledTools: [], prepSourcesConfigured: false)

    /// What the model may call right now: every hot tool, plus the deferred tools already loaded.
    /// Each loader drops out once its own catalog is exhausted, on the same rule that keeps it out
    /// of a session with no catalog — a tool offered with nothing to do invites a call that can
    /// only be refused, and each one spends an iteration of the bounded tool loop.
    public func callable(loaded: Set<String>) -> [ToolDef] {
        let toolsLeft = deferredTools.contains { !loaded.contains($0.name) }
        let skillsLeft = skills.contains { !loaded.contains(Self.loadedKey(forSkill: $0.name)) }
        return tools.filter { tool in
            switch tool.name {
            case Self.loadToolName: return toolsLeft
            case Self.loadSkillName: return skillsLeft
            default: return !tool.deferLoading || loaded.contains(tool.name)
            }
        }
    }

    /// Skills and deferred tools share one loaded set; this is what keeps their names apart in it.
    /// It lives here because `callable` above is the other reader of that convention.
    public static func loadedKey(forSkill name: String) -> String { "skill:\(name)" }

    public func tool(named name: String) -> ToolDef? {
        tools.first { $0.name == name }
    }

    public func skill(named name: String) -> Skill? {
        skills.first { $0.name == name }
    }
}
