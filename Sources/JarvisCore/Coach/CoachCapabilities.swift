import Foundation

public let coachTools = [captureScreenTool, speakTool, staySilentTool]

/// Resolved once at Start and read by both the prompt and the declared schemas, so they never
/// drift.
public struct CoachCapabilities: Sendable, Equatable {
    /// In prompt order.
    public let tools: [ToolDef]
    public let skills: [Skill]

    public init(tools: [ToolDef], skills: [Skill] = []) {
        self.tools = tools
        self.skills = skills
    }

    public var hotTools: [ToolDef] { tools.filter { !$0.deferLoading } }
    public var deferredTools: [ToolDef] { tools.filter(\.deferLoading) }
    public var catalogNames: [String] { deferredTools.map(\.name) }

    /// Loaders are fixed so a hand-edited plist can't remove one while its catalog has entries.
    public static let fixedToolNames: Set<String> =
        [captureScreenTool.name, speakToolName, staySilentTool.name, loadToolName, loadSkillName]

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
        return CoachCapabilities(
            tools: coachTools
                + (deferred.isEmpty ? [] : [loadTool(catalogNames: deferred.map(\.name))])
                + (offeredSkills.isEmpty ? [] : [loadSkill(catalogNames: offeredSkills.map(\.name))])
                + extras,
            skills: offeredSkills)
    }

    static func loaderParametersJSON(catalogNames: [String]) -> String {
        let names = catalogNames
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            .joined(separator: ",")
        return #"{"type":"object","properties":{"name":{"type":"string","enum":["#
            + names
            + #"]}},"required":["name"],"additionalProperties":false}"#
    }

    public static let `default` = compose(disabledTools: [], prepSourcesConfigured: false)

    /// A loader with nothing left to load is dropped: it only invites a refused call that spends a
    /// tool-loop iteration.
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

    public static func loadedKey(forSkill name: String) -> String { "skill:\(name)" }

    public func tool(named name: String) -> ToolDef? {
        tools.first { $0.name == name }
    }

    public func skill(named name: String) -> Skill? {
        skills.first { $0.name == name }
    }
}
