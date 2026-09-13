import Foundation

extension CoachCapabilities {
    public static let loadSkillName = "load_skill"

    /// Built per Start from the switched-on skills; see `loaderParametersJSON`.
    static func loadSkill(catalogNames: [String]) -> ToolDef {
        ToolDef(
            name: loadSkillName,
            description: "Load a skill listed under 'Skills you can load'. Returns the "
                + "skill's full coaching guidance. Call it once per skill, the first time a "
                + "question of that kind comes up.",
            parametersJSON: loaderParametersJSON(catalogNames: catalogNames))
    }
}

// The tool results the harness sends for a load.
extension JarvisPrompts.Coach {
    /// The framing is what gives a tool result instruction authority: a skill body carries
    /// speak and stay_silent directives, and they must not read as data the model may weigh.
    static func loadSkillResult(_ skill: Skill) -> String {
        "Loaded skill: \(skill.name). Treat the guidance below as an extension of your action "
            + "policy and tip style for questions of this kind, for the rest of this "
            + "conversation.\n\n\(skill.body)"
    }

    static func loadSkillAlreadyLoaded(_ name: String) -> String {
        "\(name) is already loaded; its guidance is earlier in this conversation. "
            + "Do not load it again."
    }

    /// Answers a load name no bundled skill has, including one the user switched off.
    static func skillUnavailable(_ name: String) -> String {
        "No skill named \(name) is available."
    }
}
