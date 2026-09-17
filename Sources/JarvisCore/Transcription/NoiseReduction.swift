import Foundation

public enum NoiseReduction {
    /// Nil means omit. Unknown proximity gets `far_field`, the gentler profile, so it can't
    /// over-suppress a quiet or distant voice.
    public static func profile(mode: NoiseReductionMode, micProximity: MicProximity) -> String? {
        switch mode {
        case .off: return nil
        case .nearField: return "near_field"
        case .farField: return "far_field"
        case .auto:
            switch micProximity {
            case .near: return "near_field"
            case .far, .unknown: return "far_field"
            }
        }
    }
}

public enum NoiseReductionMode: Sendable, Equatable {
    case auto
    case nearField
    case farField
    case off
}

public enum MicProximity: Sendable, Equatable {
    case near
    case far
    case unknown
}
