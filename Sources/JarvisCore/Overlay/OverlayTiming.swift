import Foundation

/// Design: wiki/overlay-timing.md
public enum OverlayTiming {
    public static func displaySeconds(for line: String, config: Config) -> TimeInterval {
        let words = line.split(whereSeparator: { $0.isWhitespace }).count
        let total = config.overlayNoticeBufferSeconds + Double(words) * config.overlaySecondsPerWord
        return min(config.overlayMaxDisplaySeconds, total)
    }
}
