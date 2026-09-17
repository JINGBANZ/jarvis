import Foundation

/// Closed on purpose, so transport, retry, timing, and lifecycle detail can never reach Activity
/// through a generic call. Producers never author copy; provider text is quoted redacted.
public enum ActivityEvent: Sendable {
    /// Persisted identity: a shipped raw value never changes.
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
        case capabilityLoaded
        case prepNotesUnavailable
    }

    /// Persisted inside the event, so part of the on-disk vocabulary.
    public enum CapabilityKind: String, Codable, Sendable {
        case tool
        case skill
    }

    case heard(speaker: Speaker, text: String)
    case manualHint(prompt: String)
    case manualExplanation(prompt: String)
    case manualCode(prompt: String)
    case screenViewed(imageBase64JPEG: String)
    /// Fixed recovery guidance only; raw failure detail stays in the debug log.
    case screenViewFailed
    case tip(lines: [String], detail: String? = nil)
    case stayedSilent
    /// The single terminal event. A closed reason set, so a producer cannot author copy.
    case sessionEnded(reason: SessionEndReason)
    case coachingCycleFailed(failure: ProviderFailure)
    case systemAudioStopped(failure: ProviderFailure)
    case settingsChangeNotApplied
    /// Sent after the replacement's first non-truncated terminal turn.
    case brainChangeApplied(previous: BrainProvider, current: BrainProvider)
    case brainRouteAdvanced(
        previous: BrainProvider, current: BrainProvider, failure: ProviderFailure)
    case brainRouteTargetSkipped(failure: ProviderFailure)
    /// `matchCount` 0 means nothing scored usefully.
    case prepNotesSearched(query: String, matchCount: Int)
    case capabilityLoaded(kind: CapabilityKind, name: String)
    /// Not a zero-match search, which would claim the notes were read. States no timing; whether
    /// the index is still building belongs in `jlog`.
    case prepNotesUnavailable

    var response: ActivityResponse? {
        guard case .tip(let lines, let detail) = self else { return nil }
        return ActivityResponse(lines: lines, detail: detail)
    }

    /// One exhaustive mapping, so an event's persisted kind can't disagree with its copy.
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
        case .tip(let lines, let detail):
            return (.tip, ActivityResponse(lines: lines, detail: detail).message, nil)
        case .stayedSilent:
            return (.stayedSilent, "🤫 stayed silent — nothing useful to add", nil)
        case .sessionEnded(let reason):
            return (.sessionEnded, "⏹ \(reason.activityMessage)", nil)
        case .coachingCycleFailed(let failure):
            return (
                .coachingCycleFailed,
                "⚠️ \(failure.activitySentenceWithoutAdvice) — coaching failed; listening continues"
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
            // This frame supplies its own verb, so it quotes the evidence, not the whole sentence.
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
        case .capabilityLoaded(let kind, let name):
            return (.capabilityLoaded, "📎 loaded the \(name) \(kind.rawValue)", nil)
        case .prepNotesUnavailable:
            return (.prepNotesUnavailable, "📎 couldn't check your prep notes — coaching without them", nil)
        }
    }
}
