import Foundation

/// How long a single overlay line should stay on screen. A deliberate hybrid of the captioning
/// reading-speed standard and our own situation: the user is mid-conversation and only *glances* at
/// the overlay (no audio echo), so the dominant cost is *noticing* the tip — a fixed buffer captions
/// don't need — on top of the length-proportional reading time. Pure logic (no OS) so it can be
/// unit-tested; the overlay just plays each line for the seconds computed here. See
/// wiki/overlay-timing.md for the full rationale.
public enum OverlayTiming {
    /// Display seconds for one line: `noticeBuffer + words × secondsPerWord`, capped at `max`. The
    /// floor emerges from the buffer (a one-word line ≈ buffer + one word's reading time), so there is
    /// no separate minimum knob. Tune the knobs in `Config`.
    public static func displaySeconds(for line: String, config: Config) -> TimeInterval {
        let words = line.split(whereSeparator: { $0.isWhitespace }).count
        let total = config.overlayNoticeBufferSeconds + Double(words) * config.overlaySecondsPerWord
        return min(config.overlayMaxDisplaySeconds, total)
    }
}
