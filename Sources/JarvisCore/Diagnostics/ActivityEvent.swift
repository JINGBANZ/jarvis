import Foundation

/// The closed set of human-visible occurrences in the coaching exchange.
///
/// Keeping this set typed and closed is what stops transport, retry, timing, and lifecycle detail
/// from reaching the Activity window through a generic logging call. Sharing one evidence stack
/// (wiki/lean-coaching-core.md, "One Event, Two Projections") does not relax that: a producer
/// chooses from these cases or it has no human-facing copy at all. A failure case carries a
/// `ProviderFailure`, whose message is redacted provider text, so what the provider said is quoted
/// inside copy this file owns rather than authored by the producer.
///
/// It lives apart from `ActivityLog` so the coaching kernel can name the human-safe vocabulary
/// without holding the concrete persistence type behind it.
public enum ActivityEvent: Sendable {
    /// Stable on-disk identity for each typed Activity event. Human copy and emoji may evolve; tools
    /// reading the complete log can use this value instead of reverse-parsing prose.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case heard
        case manualHint
        case manualExplanation
        case manualCode
        case screenViewed
        case screenViewFailed
        case tip
        case stayedSilent
        case sessionEnded
        case coachingCycleFailed = "coachingTurnFailed"
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
    case manualExplanation(prompt: String)
    case manualCode(prompt: String)
    /// Jarvis captured and viewed the screen while preparing a coaching response.
    case screenViewed(imageBase64JPEG: String)
    /// The brain chose to view the screen, but capture failed. Activity gets fixed recovery
    /// guidance while raw failure detail stays in debug.
    case screenViewFailed
    /// Jarvis displayed these coaching lines to the user.
    case tip(lines: [String], explanation: String? = nil, codeSnippet: CodeSnippet? = nil)
    /// The brain explicitly chose `stay_silent` for this turn.
    case stayedSilent
    /// The single terminal lifecycle event for a live coaching session. The reason is a closed set,
    /// so a producer cannot author copy; a provider-caused end carries the classified failure and
    /// Activity renders its sentence.
    case sessionEnded(reason: SessionEndReason)
    /// One coaching cycle exhausted its finite route budget while capture and transcription remain live. The failure carries its own sentence: the frame is fixed, and
    /// what the provider said (already redacted) is quoted inside it.
    case coachingCycleFailed(failure: ProviderFailure)
    /// The secondary system-audio transcription stopped while microphone coaching continued. The
    /// failure that stopped it is quoted, so a degraded session still says why it degraded.
    case systemAudioStopped(failure: ProviderFailure)
    /// An explicit Settings reapply failed its preflight while the existing session continued.
    case settingsChangeNotApplied
    /// A live brain replacement completed its first non-truncated terminal turn. Provider
    /// identities are enough for a fixed human-facing success notice; model transport details
    /// remain in jlog.
    case brainChangeApplied(previous: BrainProvider, current: BrainProvider)
    /// A failed target was exhausted and the next user-authorized route target became active. The
    /// failure that exhausted the old target is quoted; the frame names the new one.
    case brainRouteAdvanced(
        previous: BrainProvider, current: BrainProvider, failure: ProviderFailure)
    /// A route target was proven unavailable before a provider request could be constructed.
    case brainRouteTargetSkipped(failure: ProviderFailure)
    /// The brain looked up the user's prepared interview notes for `query`. `matchCount` is how
    /// many relevant chunks came back, 0 meaning nothing scored usefully.
    case prepNotesSearched(query: String, matchCount: Int)

    var response: ActivityResponse? {
        guard case .tip(let lines, let explanation, let code) = self else { return nil }
        return ActivityResponse(lines: lines, explanation: explanation, codeSnippet: code)
    }

    /// Keep persisted identity, human copy, and the optional screenshot payload in one exhaustive
    /// mapping so adding or editing an event cannot make its `k` disagree with what Activity shows.
    var rendered: (kind: Kind, message: String, imageBase64: String?) {
        switch self {
        case .heard(let speaker, let text):
            return (.heard, "🗣 heard (\(speaker.rawValue)): \"\(text)\"", nil)
        case .manualHint(let prompt):
            return (.manualHint, "⌨️ hint shortcut — \(prompt)", nil)
        case .manualExplanation(let prompt):
            return (.manualExplanation, "⌨️ explain more shortcut — \(prompt)", nil)
        case .manualCode(let prompt):
            return (.manualCode, "⌨️ show code shortcut — \(prompt)", nil)
        case .screenViewed(let imageBase64JPEG):
            return (.screenViewed, "👁 looking at your screen", imageBase64JPEG)
        case .screenViewFailed:
            return (
                .screenViewFailed,
                "👁 couldn't view your screen — screen capture failed; check Screen Recording permission",
                nil
            )
        case .tip(let lines, let explanation, let code):
            return (.tip, ActivityResponse(lines: lines, explanation: explanation, codeSnippet: code).message, nil)
        case .stayedSilent:
            return (.stayedSilent, "🤫 stayed silent — nothing useful to add", nil)
        case .sessionEnded(let reason):
            return (.sessionEnded, "⏹ \(reason.activityMessage)", nil)
        case .coachingCycleFailed(let failure):
            return (
                .coachingCycleFailed,
                "⚠️ \(failure.activitySentenceWithoutAdvice) — coaching cycle failed; listening continues"
                    + failure.activityAdvice,
                nil
            )
        case .systemAudioStopped(let failure):
            return (
                .systemAudioStopped,
                "⚠️ system audio stopped — \(failure.activitySentenceWithoutAdvice)"
                    + "; microphone coaching continues\(failure.activityAdvice)",
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
        case .brainRouteAdvanced(let previous, let current, let failure):
            // This frame supplies its own verb, so it quotes the evidence alone rather than the
            // failure's whole sentence.
            let detail = failure.activityDetail
            let message = if previous == current {
                "⚠️ \(previous.displayName) target couldn't respond\(detail) — continuing with the next \(current.displayName) model"
            } else {
                "⚠️ \(previous.displayName) couldn't respond\(detail) — continuing on \(current.displayName)"
            }
            return (.brainRouteAdvanced, message, nil)
        case .brainRouteTargetSkipped(let failure):
            return (
                .brainRouteTargetSkipped,
                "⚠️ \(failure.activitySentenceWithoutAdvice) — skipping it\(failure.activityAdvice)",
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
