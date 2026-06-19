import Testing
@testable import JarvisCore

@Suite struct AudioDownmixTests {
    @Test func monoPassthroughScalesToInt16() {
        let out = AudioDownmix.monoInt16([0.0, 1.0, -1.0], channels: 1)
        #expect(out == [0, 32767, -32767])
    }

    @Test func stereoAveragesChannels() {
        // frame0 = (1.0 + 0.0)/2 = 0.5 → 16383; frame1 = (-0.5 + 0.5)/2 = 0 → 0
        let out = AudioDownmix.monoInt16([1.0, 0.0, -0.5, 0.5], channels: 2)
        #expect(out.count == 2)
        #expect(out[0] == 16383)
        #expect(out[1] == 0)
    }

    @Test func clampsOutOfRangeSamples() {
        let out = AudioDownmix.monoInt16([2.0, -2.0], channels: 1)
        #expect(out == [32767, -32767])
    }

    @Test func emptyInputYieldsEmpty() {
        #expect(AudioDownmix.monoInt16([], channels: 2).isEmpty)
    }
}
