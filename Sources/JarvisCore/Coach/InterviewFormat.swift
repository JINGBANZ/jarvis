import Foundation

/// The interview format a coaching session is specialized for. Chosen once at Start — like
/// `TranscriptionPreferences.openAIExpectedLanguages` — and fixed for the whole session, never
/// guessed or reclassified mid-conversation: an automatic, in-session classifier was considered and
/// rejected, both for guessing once and locking in (misclassifies a session that shifts formats) and
/// for continuously re-guessing (the same "brittle state machine" a history-compaction design
/// already rejected — see wiki/architecture.md § Models and APIs).
public enum InterviewFormat: String, CaseIterable, Codable, Sendable, CoachingSkill {
    case coding = "coding"
    case systemDesign = "system-design"
    case behavioral = "behavioral"

    public var displayName: String {
        switch self {
        case .coding: "Coding"
        case .systemDesign: "System Design"
        case .behavioral: "Behavioral"
        }
    }

    /// Loaded from `Resources/Skills/<rawValue>.md` — a real Markdown file, not a Swift string
    /// literal, so a skill's content reads and edits like prose. Only `system-design.md` exists
    /// today: `.coding` and `.behavioral` are already reported as working well, so they stay empty
    /// rather than getting new prompt guidance nobody asked for. Missing file → empty, not a crash —
    /// an unwritten skill is a normal state, not an error.
    public var promptAddendum: String {
        guard let url = Bundle.module.url(
            forResource: rawValue, withExtension: "md", subdirectory: "Skills"),
            let body = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !body.isEmpty else {
            return ""
        }
        return "\n\n" + body
    }

    /// The addendum for an explicit choice, or — when none was made — every format's non-empty
    /// addendum concatenated, so Jarvis still has the vocabulary without guessing which format this
    /// is. See wiki/architecture.md § Models and APIs.
    public static func resolvedPromptAddendum(for format: InterviewFormat?) -> String {
        if let format { return format.promptAddendum }
        return allCases.map(\.promptAddendum).filter { !$0.isEmpty }.joined()
    }
}
