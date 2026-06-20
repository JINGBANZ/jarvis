import Foundation

/// How hard the brain model thinks before answering, passed to the Responses API as
/// `reasoning.effort`. One global setting applied to whichever `BrainModel` is selected — the four
/// levels below are supported across the GPT-5.4/5.5 family. Lower effort favors speed and fewer
/// tokens; higher effort thinks more completely. `rawValue` is the exact API string.
public enum ReasoningEffort: String, CaseIterable, Sendable {
    case none
    case low
    case medium
    case high

    /// Title-case label for the settings picker.
    public var displayName: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// `low` keeps a coaching turn fast (sub-2s target) while still allowing tool calls.
    public static let `default`: ReasoningEffort = .low
}
