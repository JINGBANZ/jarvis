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
}
