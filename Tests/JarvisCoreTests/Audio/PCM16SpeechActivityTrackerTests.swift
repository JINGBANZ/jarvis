import Foundation
import Testing
@testable import JarvisCore

@Suite struct PCM16SpeechActivityTrackerTests {
    @Test func reportsOneOnsetAndOneDelayedRelease() {
        var tracker = PCM16SpeechActivityTracker(releaseDelay: 0.5)

        #expect(tracker.observe(pcm16: pcm(amplitude: 40), at: 0) == nil)
        #expect(tracker.observe(pcm16: pcm(amplitude: 1_000), at: 0.1) == true)
        #expect(tracker.observe(pcm16: pcm(amplitude: 900), at: 0.2) == nil)
        #expect(tracker.observe(pcm16: pcm(amplitude: 40), at: 0.4) == nil)
        #expect(tracker.observe(pcm16: pcm(amplitude: 40), at: 0.71) == false)
        #expect(tracker.observe(pcm16: pcm(amplitude: 40), at: 0.8) == nil)
    }

    @Test func resetEndsAnActiveEpisodeAndRearmsDetection() {
        var tracker = PCM16SpeechActivityTracker()

        #expect(tracker.observe(pcm16: pcm(amplitude: 1_000), at: 0) == true)
        #expect(tracker.reset() == false)
        #expect(tracker.reset() == nil)
        #expect(tracker.observe(pcm16: pcm(amplitude: 1_000), at: 1) == true)
    }

    private func pcm(amplitude: Int16, count: Int = 480) -> Data {
        let samples = (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
        return samples.withUnsafeBytes { Data($0) }
    }
}
