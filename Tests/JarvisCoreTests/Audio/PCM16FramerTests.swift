import Testing
@testable import JarvisCore

@Suite struct PCM16FramerTests {
    /// AEC3 only accepts fixed 10 ms frames (480 samples at 48 kHz), but capture delivers arbitrary
    /// chunk sizes. The framer re-chunks a stream of samples into exact `frameSize` frames, holding
    /// the leftover for the next push.

    @Test func emitsNothingUntilAFullFrameAccumulates() {
        var framer = PCM16Framer(frameSize: 480)
        #expect(framer.push(Array(repeating: 1, count: 240)).isEmpty)
    }

    @Test func emitsOneFrameWhenExactlyFull() {
        var framer = PCM16Framer(frameSize: 480)
        let frames = framer.push(Array(repeating: 7, count: 480))
        #expect(frames.count == 1)
        #expect(frames[0] == Array(repeating: 7, count: 480))
    }

    @Test func accumulatesAcrossPushes() {
        var framer = PCM16Framer(frameSize: 480)
        #expect(framer.push(Array(repeating: 3, count: 240)).isEmpty)
        let frames = framer.push(Array(repeating: 3, count: 240))   // now 480 total
        #expect(frames.count == 1)
        #expect(frames[0].count == 480)
    }

    @Test func emitsMultipleFramesAndRetainsRemainder() {
        var framer = PCM16Framer(frameSize: 480)
        let frames = framer.push(Array(repeating: 5, count: 1000))   // 2 frames + 40 leftover
        #expect(frames.count == 2)
        // The 40-sample remainder is retained: 440 more completes exactly one more frame.
        let next = framer.push(Array(repeating: 5, count: 440))
        #expect(next.count == 1)
    }

    @Test func emptyPushEmitsNothing() {
        var framer = PCM16Framer(frameSize: 480)
        #expect(framer.push([]).isEmpty)
    }
}
