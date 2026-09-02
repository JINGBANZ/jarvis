import Foundation

/// A named coaching specialization Jarvis's system prompt can adopt for a session.
///
/// `InterviewFormat` is the only conformer today. The protocol exists so a structurally different
/// kind of skill — not just another interview format — could conform on its own type later without
/// touching `InterviewFormat` or the code that consumes `any CoachingSkill`.
public protocol CoachingSkill: Sendable {
    /// Shown in Settings.
    var displayName: String { get }
    /// Appended to the coaching system prompt when this skill is the session's chosen format.
    /// Empty when this skill has no additional guidance yet.
    var promptAddendum: String { get }
}
