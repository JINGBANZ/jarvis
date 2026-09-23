import Foundation

extension CoachCapabilities {
    public static let loadSkillName = "load_skill"

    static func loadSkill(catalogNames: [String]) -> ToolDef {
        ToolDef(
            name: loadSkillName,
            description: "Load a skill listed under 'Skills you can load'. Returns the "
                + "skill's full coaching guidance. Call it once per session for each skill, the "
                + "first time a question of that kind comes up.",
            parametersJSON: loaderParametersJSON(catalogNames: catalogNames))
    }
}

extension JarvisPrompts.Coach {
    /// The framing makes the skill's speak and stay_silent directives read as policy, not data.
    static func loadSkillResult(_ skill: Skill) -> String {
        "Loaded skill: \(skill.name). Treat the guidance below as an extension of your action "
            + "policy and tip style for questions of this kind, for the rest of this "
            + "conversation.\n\n\(skill.body)"
    }

    static func loadSkillAlreadyLoaded(_ name: String) -> String {
        "\(name) is already loaded; its guidance is earlier in this conversation. "
            + "Do not load it again."
    }

    static func skillUnavailable(_ name: String) -> String {
        "No skill named \(name) is available."
    }
}
