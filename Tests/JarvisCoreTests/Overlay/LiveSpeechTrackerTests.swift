import Foundation
import Testing
@testable import JarvisCore

@Suite struct LiveSpeechTrackerTests {
    @Test func pendingWorkShowsSpeakingWithItsStart() {
        let tracker = LiveSpeechTracker()
        tracker.update(.pending(since: 4), for: .them)
        #expect(tracker.snapshot() == [.them: .speaking(since: 4)])
    }

    @Test func interimTextTakesPrecedenceWhileSpeechIsPending() {
        let tracker = LiveSpeechTracker()
        tracker.update(.pending(since: 4), for: .them)
        tracker.updateInterim("let's talk about ind", for: .them)
        #expect(tracker.snapshot() == [.them: .interim("let's talk about ind")])
    }

    @Test func settlingClearsTheSpeakersInterimText() {
        let tracker = LiveSpeechTracker()
        tracker.update(.pending(since: 4), for: .me)
        tracker.updateInterim("I would start", for: .me)
        tracker.update(.settled, for: .me)
        #expect(tracker.snapshot().isEmpty)

        tracker.update(.pending(since: 9), for: .me)
        #expect(tracker.snapshot() == [.me: .speaking(since: 9)], "stale interim must not come back")
    }

    @Test func speakersAreTrackedIndependently() {
        let tracker = LiveSpeechTracker()
        tracker.update(.pending(since: nil), for: .me)
        tracker.updateInterim("so the cache", for: .them)
        tracker.updateInterim(nil, for: .them)
        #expect(tracker.snapshot() == [.me: .speaking(since: nil)])
    }
}
