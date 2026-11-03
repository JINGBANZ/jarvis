import Foundation

/// Raw values are the Carbon `EventHotKeyID` ids.
public enum CoachingShortcut: UInt32, CaseIterable, Sendable {
    case hint = 1
    case explainMore = 2
    case showCode = 3
    case previousDetail = 4
    case nextDetail = 5
    case collapseOverlay = 6
    case newSession = 7
    case toggleCoachingMode = 8

    public var title: String {
        switch self {
        case .hint: "Give me a hint"
        case .explainMore: "Explain more"
        case .showCode: "Show code"
        case .previousDetail: "Previous detail"
        case .nextDetail: "Next detail"
        case .collapseOverlay: "Collapse overlay"
        case .newSession: "Start new session"
        case .toggleCoachingMode: "Toggle manual mode"
        }
    }

    public var triggerReason: TriggerReason? {
        switch self {
        case .hint: .manualHint
        case .explainMore: .manualExplanation
        case .showCode: .manualCode
        case .previousDetail, .nextDetail, .collapseOverlay, .newSession, .toggleCoachingMode: nil
        }
    }

    /// A press that asks Jarvis to act gets audible feedback while stopped; overlay navigation
    /// declines silently.
    public var beepsWhileStopped: Bool {
        triggerReason != nil || self == .newSession || self == .toggleCoachingMode
    }
}
