import Testing
@testable import JarvisCore

@Suite struct UtteranceBufferTests {
    @Test func joinsFragmentsWithSpaces() {
        let b = UtteranceBuffer()
        b.append("Hey jarvis")
        b.append("what's the complexity")
        let r = b.flush()
        #expect(r.text == "Hey jarvis what's the complexity")
        #expect(r.fragments == 2)
    }

    @Test func flushClears() {
        let b = UtteranceBuffer()
        b.append("a"); _ = b.flush()
        let r = b.flush()
        #expect(r.text == "")
        #expect(r.fragments == 0)
    }

    @Test func ignoresEmptyFragments() {
        let b = UtteranceBuffer()
        b.append(""); b.append("hi")
        #expect(b.flush().fragments == 1)
    }

    /// The point of coalescing: fragments of one spoken sentence join into a single utterance, so a
    /// sentence split across VAD fragments drives one turn, not several.
    @Test func joinsAcrossFragments() {
        let b = UtteranceBuffer()
        b.append("hey")
        b.append("can you help")
        #expect(b.flush().text == "hey can you help")
    }

    @Test func pendingTranscriptionDefersDrainWithoutDiscardingFragments() {
        let b = UtteranceBuffer()
        b.append("Violet Lantern begins.")

        #expect(b.drainIfSettled(hasPendingTranscriptions: true)
                == .waitingForPendingTranscriptions)

        b.append("Describe your agentic project.")
        #expect(b.drainIfSettled(hasPendingTranscriptions: true)
                == .waitingForPendingTranscriptions)

        b.append("Violet Lantern ends.")
        #expect(b.drainIfSettled(hasPendingTranscriptions: false)
                == .ready(
                    text: "Violet Lantern begins. Describe your agentic project. "
                        + "Violet Lantern ends.",
                    fragments: 3))
        #expect(b.drainIfSettled(hasPendingTranscriptions: false) == .empty)
    }

    @Test func terminalItemWithoutTextRearmsDeferredTurnExactlyOnce() {
        let b = UtteranceBuffer()
        b.append("Preserve this completed fragment.")
        #expect(b.drainIfSettled(hasPendingTranscriptions: true)
                == .waitingForPendingTranscriptions)

        #expect(!b.shouldResumeAfterPendingTranscriptionsSettle(
            hasPendingTranscriptions: true))
        #expect(b.shouldResumeAfterPendingTranscriptionsSettle(
            hasPendingTranscriptions: false))
        #expect(!b.shouldResumeAfterPendingTranscriptionsSettle(
            hasPendingTranscriptions: false))
        #expect(b.drainIfSettled(hasPendingTranscriptions: false)
                == .ready(text: "Preserve this completed fragment.", fragments: 1))
    }

    @Test func genuinelySeparateTurnsDrainIndependently() {
        let b = UtteranceBuffer()
        b.append("Separate question one.")
        #expect(b.drainIfSettled(hasPendingTranscriptions: false)
                == .ready(text: "Separate question one.", fragments: 1))

        b.append("Separate question two.")
        #expect(b.drainIfSettled(hasPendingTranscriptions: false)
                == .ready(text: "Separate question two.", fragments: 1))
    }
}
