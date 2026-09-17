import Foundation
import Testing
@testable import JarvisCore

@Suite struct NoiseReductionTests {
    @Test func autoResolvesFromProximity() {
        #expect(NoiseReduction.profile(mode: .auto, micProximity: .near) == "near_field")
        #expect(NoiseReduction.profile(mode: .auto, micProximity: .far) == "far_field")
        #expect(NoiseReduction.profile(mode: .auto, micProximity: .unknown) == "far_field")
    }

    @Test func explicitModesIgnoreProximity() {
        for proximity in [MicProximity.near, .far, .unknown] {
            #expect(NoiseReduction.profile(mode: .nearField, micProximity: proximity) == "near_field")
            #expect(NoiseReduction.profile(mode: .farField, micProximity: proximity) == "far_field")
            #expect(NoiseReduction.profile(mode: .off, micProximity: proximity) == nil)
        }
    }

    @Test func offIsNil() {
        #expect(NoiseReduction.profile(mode: .off, micProximity: .near) == nil)
    }
}
