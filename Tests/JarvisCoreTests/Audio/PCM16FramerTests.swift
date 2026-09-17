import Testing
@testable import JarvisCore

@Suite struct PCM16FramerTests {
    /// 480 is AEC3's fixed 10 ms frame at 48 kHz.

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
        let frames = framer.push(Array(repeating: 3, count: 240))
        #expect(frames.count == 1)
        #expect(frames[0].count == 480)
    }

    @Test func emitsMultipleFramesAndRetainsRemainder() {
        var framer = PCM16Framer(frameSize: 480)
        let frames = framer.push(Array(repeating: 5, count: 1000))
        #expect(frames.count == 2)
        // 40 left over plus 440 completes one frame.
        let next = framer.push(Array(repeating: 5, count: 440))
        #expect(next.count == 1)
    }

    @Test func emptyPushEmitsNothing() {
        var framer = PCM16Framer(frameSize: 480)
        #expect(framer.push([]).isEmpty)
    }
}
