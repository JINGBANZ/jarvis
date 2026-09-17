import JarvisCore

/// The only place the four head parts map to their pages.
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
