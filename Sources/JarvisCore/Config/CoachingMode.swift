import Foundation

/// Whether finalized speech and silence start coaching on their own, or only a coaching shortcut
/// does. Transcription runs the same way in both.
public enum CoachingMode: String, Sendable, CaseIterable {
    case automatic
    case manual

    public var toggled: CoachingMode {
        switch self {
        case .automatic: .manual
        case .manual: .automatic
        }
    }
}
