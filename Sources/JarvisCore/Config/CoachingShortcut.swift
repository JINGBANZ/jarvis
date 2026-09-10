import Foundation

/// Stable identities shared by shortcut preferences and the app's Carbon event routing.
public enum CoachingShortcut: UInt32, CaseIterable, Sendable {
    case hint = 1
    case explainMore = 2

    public var title: String {
        switch self {
        case .hint: "Give me a hint"
        case .explainMore: "Explain more"
        }
    }

    public var triggerReason: TriggerReason {
        switch self {
        case .hint: .manualHint
        case .explainMore: .manualExplanation
        }
    }
}
