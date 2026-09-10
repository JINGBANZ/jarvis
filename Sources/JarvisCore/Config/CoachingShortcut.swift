import Foundation

/// Stable identities shared by shortcut preferences and the app's Carbon event routing.
public enum CoachingShortcut: UInt32, CaseIterable, Sendable {
    case hint = 1
    case explainMore = 2
    case showCode = 3

    public var title: String {
        switch self {
        case .hint: "Give me a hint"
        case .explainMore: "Explain more"
        case .showCode: "Show code"
        }
    }

    public var triggerReason: TriggerReason {
        switch self {
        case .hint: .manualHint
        case .explainMore: .manualExplanation
        case .showCode: .manualCode
        }
    }
}
