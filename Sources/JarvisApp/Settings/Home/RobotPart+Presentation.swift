import JarvisCore

/// How the Settings window names and draws each part of Jarvis's head.
extension RobotPart {
    var title: String {
        switch self {
        case .brain: "Brain"
        case .ear: "Ear"
        case .eye: "Eye"
        case .mouth: "Mouth"
        }
    }

    var symbolName: String {
        switch self {
        case .brain: "brain"
        case .ear: "ear"
        case .eye: "eye"
        case .mouth: "mouth"
        }
    }
}
