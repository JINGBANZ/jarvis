import Foundation

/// The closed set of human-visible occurrences in the coaching exchange.
///
/// Keeping this set typed and closed is what stops transport, retry, timing, lifecycle, and raw
/// error detail from reaching the Activity window through a generic logging call. Sharing one
/// evidence stack (wiki/lean-coaching-core.md, "One Event, Two Projections") does not relax that:
/// a producer chooses from these cases or it has no human-facing copy at all.
///
/// It lives apart from `ActivityLog` so the coaching kernel can name the human-safe vocabulary
/// without holding the concrete persistence type behind it.
public enum ActivityEvent: Sendable {
    /// Stable on-disk identity for each typed Activity event. Human copy and emoji may evolve; tools
    /// reading the complete log can use this value instead of reverse-parsing prose.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case heard
        case manualHint
        case screenViewed
        case screenViewFailed
        case tip
        case stayedSilent
        case sessionEnded
        case coachingTurnFailed
        case systemAudioStopped
        case settingsChangeNotApplied
        case brainChangeApplied
        case brainRouteAdvanced
        case brainRouteTargetSkipped
        case prepNotesSearched
    }

    /// A finalized utterance from the user (`me`) or interviewer (`them`).
    case heard(speaker: Speaker, text: String)
    /// The user explicitly requested help through the manual-hint shortcut.
    case manualHint(prompt: String)
    /// Jarvis captured and viewed the screen while preparing a coaching response.
    case screenViewed(imageBase64JPEG: String)
    /// The brain chose to view the screen, but capture failed. Activity gets fixed recovery
    /// guidance while raw failure detail stays in debug.
    case screenViewFailed
    /// Jarvis displayed these coaching lines to the user.
    case tip(lines: [String])
    /// The brain explicitly chose `stay_silent` for this turn.
    case stayedSilent
    /// The single terminal lifecycle event for a live coaching session. The reason is a closed,
    /// sanitized set so raw errors cannot leak into Activity.
    case sessionEnded(reason: SessionEndReason)
    /// One coaching response failed temporarily and a fresh attempt will retry while capture and
    /// transcription remain live. Provider identity is enough; raw error detail stays in debug.
    case coachingTurnFailed(provider: BrainProvider)
    /// The secondary system-audio transcription stopped while microphone coaching continued.
    case systemAudioStopped
    /// An explicit Settings reapply failed its preflight while the existing session continued.
    case settingsChangeNotApplied
    /// A live brain replacement completed its first non-truncated terminal turn. Provider
    /// identities are enough for a fixed human-facing success notice; model transport details
    /// remain in jlog.
    case brainChangeApplied(previous: BrainProvider, current: BrainProvider)
    /// A failed target was exhausted and the next user-authorized route target became active.
    case brainRouteAdvanced(previous: BrainProvider, current: BrainProvider)
    /// A route target was proven unavailable before a provider request could be constructed.
    case brainRouteTargetSkipped(provider: BrainProvider)
    /// The brain looked up the user's prepared interview notes for `query`. `matchCount` is how
    /// many relevant chunks came back, 0 meaning nothing scored usefully.
    case prepNotesSearched(query: String, matchCount: Int)

    /// Keep persisted identity, human copy, and the optional screenshot payload in one exhaustive
    /// mapping so adding or editing an event cannot make its `k` disagree with what Activity shows.
    var rendered: (kind: Kind, message: String, imageBase64: String?) {
        switch self {
        case .heard(let speaker, let text):
            return (.heard, "🗣 heard (\(speaker.rawValue)): \"\(text)\"", nil)
        case .manualHint(let prompt):
            return (.manualHint, "⌨️ hint shortcut — \(prompt)", nil)
        case .screenViewed(let imageBase64JPEG):
            return (.screenViewed, "👁 looking at your screen", imageBase64JPEG)
        case .screenViewFailed:
            return (
                .screenViewFailed,
                "👁 couldn't view your screen — screen capture failed; check Screen Recording permission",
                nil
            )
        case .tip(let lines):
            return (.tip, "💬 \(lines.joined(separator: " "))", nil)
        case .stayedSilent:
            return (.stayedSilent, "🤫 stayed silent — nothing useful to add", nil)
        case .sessionEnded(let reason):
            return (.sessionEnded, "⏹ \(reason.activityMessage)", nil)
        case .coachingTurnFailed(let provider):
            return (
                .coachingTurnFailed,
                "⚠️ \(provider.displayName) couldn't finish the response — retrying while listening continues",
                nil
            )
        case .systemAudioStopped:
            return (
                .systemAudioStopped,
                "⚠️ system audio stopped — microphone coaching continues; check jarvis-debug.log",
                nil
            )
        case .settingsChangeNotApplied:
            return (
                .settingsChangeNotApplied,
                "⚠️ settings change wasn't applied — current coaching session continues; check Settings → Brain",
                nil
            )
        case .brainChangeApplied(let previous, let current):
            let message = if previous == current {
                "🧠 brain change applied — \(current.displayName) setup is active"
            } else {
                "🧠 brain switch applied — \(previous.displayName) → \(current.displayName)"
            }
            return (.brainChangeApplied, message, nil)
        case .brainRouteAdvanced(let previous, let current):
            let message = if previous == current {
                "⚠️ \(previous.displayName) target couldn't respond — continuing with the next \(current.displayName) model"
            } else {
                "⚠️ \(previous.displayName) couldn't respond — continuing on \(current.displayName)"
            }
            return (.brainRouteAdvanced, message, nil)
        case .brainRouteTargetSkipped(let provider):
            return (
                .brainRouteTargetSkipped,
                "⚠️ \(provider.displayName) target is unavailable — skipping it",
                nil
            )
        case .prepNotesSearched(let query, let matchCount):
            let message = matchCount > 0
                ? "📎 checked prep notes for \"\(query)\" — found \(matchCount) match"
                    + "\(matchCount == 1 ? "" : "es")"
                : "📎 checked prep notes for \"\(query)\" — nothing relevant found"
            return (.prepNotesSearched, message, nil)
        }
    }
}
