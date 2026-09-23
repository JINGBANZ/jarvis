import Foundation

public let coachTools = [captureScreenTool, speakTool, staySilentTool]

/// Resolved once at Start and read by both the prompt and the declared schemas, so they never
/// drift. `tools` is sent byte-identical on every request of the session: a changed list misses
/// the prompt cache from the tools block on and, on Claude Fable 5.1, invalidates replayed thinking.
public struct CoachCapabilities: Sendable, Equatable {
    /// The declared list, in prompt order.
    public let tools: [ToolDef]
    /// Named in the prompt's catalog, loaded through `load_tool`, called through `call_tool`,
    /// never declared.
    public let deferredTools: [ToolDef]
    public let skills: [Skill]

    public init(tools: [ToolDef], deferredTools: [ToolDef] = [], skills: [Skill] = []) {
        self.tools = tools
        self.deferredTools = deferredTools
        self.skills = skills
    }

    public var catalogNames: [String] { deferredTools.map(\.name) }

    /// Loaders are fixed so a hand-edited plist can't remove one while its catalog has entries.
    public static let fixedToolNames: Set<String> = [
        captureScreenTool.name, speakToolName, staySilentTool.name,
        loadToolName, callToolName, loadSkillName,
    ]

    /// `prepSourcesConfigured` means sources are configured, not that the index has been built.
    /// Disabled names that match nothing or name a fixed tool are ignored.
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
        let catalogNames = deferred.map(\.name)
        return CoachCapabilities(
            tools: coachTools
                + (deferred.isEmpty ? [] : [loadTool(catalogNames: catalogNames),
                                            callTool(catalogNames: catalogNames)])
                + (offeredSkills.isEmpty ? [] : [loadSkill(catalogNames: offeredSkills.map(\.name))])
                + extras.filter { !$0.deferLoading },
            deferredTools: deferred,
            skills: offeredSkills)
    }

    static func loaderParametersJSON(catalogNames: [String]) -> String {
        #"{"type":"object","properties":{"name":{"type":"string","enum":["#
            + catalogEnumValues(catalogNames)
            + #"]}},"required":["name"],"additionalProperties":false}"#
    }

    static func catalogEnumValues(_ catalogNames: [String]) -> String {
        catalogNames
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            .joined(separator: ",")
    }

    public static let `default` = compose(disabledTools: [], prepSourcesConfigured: false)

    /// What a request may call, never what it declares: a loader with nothing left to load drops
    /// out, and `call_tool` joins once a deferred tool is loaded. The choice sits outside the cached
    /// prefix and the thinking check, so it can change per request while `tools` cannot.
    public func callableNames(loaded: Set<String>) -> [String] {
        let toolsLeft = deferredTools.contains { !loaded.contains($0.name) }
        let toolLoaded = deferredTools.contains { loaded.contains($0.name) }
        let skillsLeft = skills.contains { !loaded.contains(Self.loadedKey(forSkill: $0.name)) }
        return tools.map(\.name).filter { name in
            switch name {
            case Self.loadToolName: toolsLeft
            case Self.callToolName: toolLoaded
            case Self.loadSkillName: skillsLeft
            default: true
            }
        }
    }

    /// Why a raw call will not run. Only a declared name runs, the norm every agent follows: a
    /// deferred tool called by its own name is pointed at `call_tool`, and a malformed routed call
    /// is answered with the routed tool's schema, not `call_tool`'s.
    public enum CallRejection: Equatable, Sendable {
        case notCallableByName(String)
        case unavailable(String)
        case malformed(ToolDef)
    }

    /// Nil when `raw` names a declared tool and its arguments parsed.
    public func rejection(for raw: RawToolCall, parsed: ToolInvocation?) -> CallRejection? {
        guard let declared = tools.first(where: { $0.name == raw.name }) else {
            return deferredTools.contains { $0.name == raw.name }
                ? .notCallableByName(raw.name) : .unavailable(raw.name)
        }
        if parsed != nil { return nil }
        guard raw.name == Self.callToolName,
              let routed = ToolInvocation.routedToolName(argumentsJSON: raw.argumentsJSON),
              !Self.fixedToolNames.contains(routed) else { return .malformed(declared) }
        if let target = deferredTools.first(where: { $0.name == routed }) { return .malformed(target) }
        return .unavailable(routed)
    }

    public static func loadedKey(forSkill name: String) -> String { "skill:\(name)" }

    /// Declared or deferred: the runner routes a `call_tool` call to a deferred tool by name.
    public func tool(named name: String) -> ToolDef? {
        tools.first { $0.name == name } ?? deferredTools.first { $0.name == name }
    }

    public func skill(named name: String) -> Skill? {
        skills.first { $0.name == name }
    }
}
