import Foundation
import Testing
@testable import JarvisCore

@Suite struct NoiseReductionTests {
    /// `.auto` picks the wire profile from the detected mic proximity: a close mic (headset/AirPods)
    /// gets near_field, a distant mic (built-in/monitor) gets far_field, and an undetectable device
    /// falls back to far_field (the safe, gentler default).
    @Test func autoResolvesFromProximity() {
        #expect(NoiseReduction.profile(mode: .auto, micProximity: .near) == "near_field")
        #expect(NoiseReduction.profile(mode: .auto, micProximity: .far) == "far_field")
        #expect(NoiseReduction.profile(mode: .auto, micProximity: .unknown) == "far_field")
    }

    /// An explicitly pinned mode ignores the detected proximity entirely.
    @Test func explicitModesIgnoreProximity() {
        for proximity in [MicProximity.near, .far, .unknown] {
            #expect(NoiseReduction.profile(mode: .nearField, micProximity: proximity) == "near_field")
            #expect(NoiseReduction.profile(mode: .farField, micProximity: proximity) == "far_field")
            #expect(NoiseReduction.profile(mode: .off, micProximity: proximity) == nil)
        }
    }

    /// `.off` disables noise reduction (the session omits the key — see RealtimeSession.sessionUpdate).
    @Test func offIsNil() {
        #expect(NoiseReduction.profile(mode: .off, micProximity: .near) == nil)
    }
}
