import Foundation

/// The interview format a coaching session is specialized for. Chosen once at Start — like
/// `TranscriptionPreferences.openAIExpectedLanguages` — and fixed for the whole session, never
/// guessed or reclassified mid-conversation. See wiki/decisions.md (2026-09-01) for why: an
/// automatic, in-session classifier was considered and rejected, both for guessing once and locking
/// in (misclassifies a session that shifts formats) and for continuously re-guessing (the "brittle
/// state machine" a 2026-08-07 decision already rejected for history compaction).
public enum InterviewFormat: String, CaseIterable, Codable, Sendable, CoachingSkill {
    case coding
    case systemDesign
    case behavioral

    public var displayName: String {
        switch self {
        case .coding: "Coding"
        case .systemDesign: "System Design"
        case .behavioral: "Behavioral"
        }
    }

    /// Only `.systemDesign` has content today. `.coding` and `.behavioral` are already reported as
    /// working well, so they stay empty rather than getting new prompt guidance nobody asked for.
    public var promptAddendum: String {
        switch self {
        case .coding, .behavioral:
            ""
        case .systemDesign:
            """

            # Interview format: system design
            This is a system-design interview. The discussion typically moves through: clarifying
            functional requirements, non-functional requirements (scale, latency, consistency), API
            design, data model, high-level architecture, then a deep dive into specific components
            and their trade-offs — but the candidate may revisit an earlier stage at any point. Infer
            which of these "me" is currently addressing from what they just said, and keep your tip
            scoped to that stage — a data-model tip is unhelpful while they are still defining the
            API contract, and vice versa.
            """
        }
    }

    /// The addendum for an explicit choice, or — when none was made — every format's non-empty
    /// addendum concatenated, so Jarvis still has the vocabulary without guessing which format this
    /// is. See wiki/decisions.md (2026-09-01).
    public static func resolvedPromptAddendum(for format: InterviewFormat?) -> String {
        if let format { return format.promptAddendum }
        return allCases.map(\.promptAddendum).filter { !$0.isEmpty }.joined()
    }
}
