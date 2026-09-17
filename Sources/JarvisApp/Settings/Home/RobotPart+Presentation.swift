import JarvisCore

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
