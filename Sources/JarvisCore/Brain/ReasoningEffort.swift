import Foundation

/// `rawValue` is the exact Responses API `reasoning.effort` string.
public enum ReasoningEffort: String, CaseIterable, Sendable, Comparable {
    case none
    case low
    case medium
    case high

    public static func < (lhs: ReasoningEffort, rhs: ReasoningEffort) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// The cap covers reasoning and output together, so a low cap returns incomplete with no
    /// output. Runaway guards scaled with effort; `high` is OpenAI's recommended 25k reasoning
    /// reserve.
    public var maxOutputTokens: Int {
        switch self {
        case .none: return 1_024
        case .low: return 2_048
        case .medium: return 8_192
        case .high: return 25_000
        }
    }
}
