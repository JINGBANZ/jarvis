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

    /// The point of coalescing: a wake word split across fragments is detected on the JOINED text,
    /// not on the first fragment alone.
    @Test func wakeWordDetectedOnCoalescedUtterance() {
        let b = UtteranceBuffer()
        b.append("hey")                       // not an address by itself
        b.append("jarvis can you help")
        #expect(!DirectAddress.isAddressed("hey"))
        #expect(DirectAddress.isAddressed(b.flush().text))
    }
}
