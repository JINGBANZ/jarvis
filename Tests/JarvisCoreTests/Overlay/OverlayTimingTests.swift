import Testing
import Foundation
@testable import JarvisCore

@Suite struct OverlayTimingTests {
    private let config = Config.default   // buffer 2.0, perWord 0.35, max 8

    /// A longer line stays up longer than a shorter one — the length-proportional part of the model.
    @Test func longerLinesShowLonger() {
        let short = OverlayTiming.displaySeconds(for: "Ask their budget.", config: config)
        let long = OverlayTiming.displaySeconds(
            for: "Ask about their budget and timeline before you pitch anything specific to them today.",
            config: config)
        #expect(long > short)
    }

    /// Duration is the fixed notice buffer plus reading time (words × secondsPerWord).
    @Test func isBufferPlusReadingTime() {
        // 2.0 + 6 × 0.35 = 4.1, below the 8s cap.
        let line = "one two three four five six"
        #expect(abs(OverlayTiming.displaySeconds(for: line, config: config) - 4.1) < 0.0001)
    }

    /// The floor emerges from the buffer: even a one-word hint gets buffer + one word, never less than
    /// the buffer itself — long enough for a glancing user to catch it.
    @Test func shortLineFloorsAtBufferPlusOneWord() {
        let one = OverlayTiming.displaySeconds(for: "Pause", config: config)
        #expect(abs(one - (config.overlayNoticeBufferSeconds + config.overlaySecondsPerWord)) < 0.0001)
        #expect(one >= config.overlayNoticeBufferSeconds)
    }

    /// An unusually long line is capped rather than lingering (and delaying the next queued tip).
    @Test func clampsDownToMaximum() {
        let wordy = Array(repeating: "word", count: 60).joined(separator: " ")
        #expect(OverlayTiming.displaySeconds(for: wordy, config: config) == config.overlayMaxDisplaySeconds)
    }

    /// Surrounding/duplicated whitespace doesn't inflate the word count.
    @Test func ignoresExtraWhitespace() {
        let padded = OverlayTiming.displaySeconds(for: "  one   two  three  ", config: config)
        let tidy = OverlayTiming.displaySeconds(for: "one two three", config: config)
        #expect(padded == tidy)
    }
}
