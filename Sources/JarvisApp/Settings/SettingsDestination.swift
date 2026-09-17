import JarvisCore

/// Every page the Settings window can show. The hub is `home`; each other case is one section.
/// The four head parts map to their pages here and nowhere else.
enum SettingsDestination: String, CaseIterable, Sendable {
    case home, brain, ear, eye, mouth, connections, tools, skills, shortcuts, activity

    init(_ part: RobotPart) {
        switch part {
        case .brain: self = .brain
        case .ear: self = .ear
        case .eye: self = .eye
        case .mouth: self = .mouth
        }
    }

    /// The head part this page configures, if any.
    var part: RobotPart? {
        switch self {
        case .brain: .brain
        case .ear: .ear
        case .eye: .eye
        case .mouth: .mouth
        case .home, .connections, .tools, .skills, .shortcuts, .activity: nil
        }
    }
}
