import Foundation
import Testing
@testable import JarvisCore

@Suite struct AdaptiveAudioActivityDetectorTests {
    @Test func adaptiveFloorRejectsBackgroundAndHysteresisReleasesActivity() {
        let configuration = AudioContinuityWitness.ActivityConfiguration(
            initialNoiseFloorRMS: 100,
            minimumNoiseFloorRMS: 20,
            minimumActiveRMS: 300,
            minimumActivePeak: 600,
            activationMultiplier: 3,
            releaseMultiplier: 1.5,
            noiseAdaptationRate: 0.2
        )
        var detector = AdaptiveAudioActivityDetector(configuration: configuration)

        for _ in 0..<20 {
            #expect(!detector.observe(pcm16: pcm(amplitude: 150)).isActive)
        }
        #expect(detector.noiseFloorRMS > 100)
        #expect(detector.observe(pcm16: pcm(amplitude: 1_000)).isActive)
        #expect(detector.observe(pcm16: pcm(amplitude: 700)).isActive)
        #expect(!detector.observe(pcm16: pcm(amplitude: 100)).isActive)
    }

    @Test func emptyAndOddTrailingBytesRetainNoSamples() {
        var detector = AdaptiveAudioActivityDetector(configuration: .init())
        #expect(detector.observe(pcm16: Data()).sampleCount == 0)
        #expect(detector.observe(pcm16: Data([0x01])).sampleCount == 0)
        #expect(detector.observe(pcm16: Data([0xE8, 0x03, 0xFF])).sampleCount == 1)
    }

    private func pcm(amplitude: Int16, count: Int = 480) -> Data {
        let samples = (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
        return samples.withUnsafeBytes { Data($0) }
    }
}
