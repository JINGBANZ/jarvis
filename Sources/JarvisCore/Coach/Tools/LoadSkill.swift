import Foundation

extension CoachCapabilities {
    public static let loadSkillName = "load_skill"

    static func loadSkill(catalogNames: [String]) -> ToolDef {
        ToolDef(
            name: loadSkillName,
            description: "Load the full app-provided guidance for one skill in Available skills. Load "
                + "each applicable skill once per session before its first use. Its guidance "
                + "applies for the rest of the session and remains earlier in the conversation.",
            parametersJSON: loaderParametersJSON(catalogNames: catalogNames))
    }
}

extension JarvisPrompts.Coach {
    /// App-provided skill guidance applies within the common response policy.
    static func loadSkillResult(_ skill: Skill) -> String {
        "Loaded skill: \(skill.name). Apply the app-provided guidance below when it fits the current "
            + "task, within your response policy, for the rest of this conversation.\n\n\(skill.body)"
    }

    static func loadSkillAlreadyLoaded(_ name: String) -> String {
        "\(name) is already loaded; its guidance is earlier in this conversation. "
            + "Do not load it again."
    }

    static func skillUnavailable(_ name: String) -> String {
        "No skill named \(name) is available."
    }
}
