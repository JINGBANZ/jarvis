import Foundation

/// Small, stateful PCM16 activity detector for continuity diagnostics. It keeps only an adaptive
/// RMS noise floor and a hysteresis bit; input samples never escape `observe`.
struct AdaptiveAudioActivityDetector {
    struct Observation {
        let sampleCount: Int
        let isActive: Bool
    }

    private let configuration: AudioContinuityWitness.ActivityConfiguration
    private var noiseFloorRMS: Double
    private(set) var isActive = false

    init(configuration: AudioContinuityWitness.ActivityConfiguration) {
        self.configuration = configuration
        noiseFloorRMS = configuration.initialNoiseFloorRMS
    }

    mutating func observe(pcm16: Data) -> Observation {
        let levels = Self.levels(in: pcm16)
        guard levels.sampleCount > 0 else {
            isActive = false
            return Observation(sampleCount: 0, isActive: false)
        }

        let activationRMS = max(configuration.minimumActiveRMS,
                                noiseFloorRMS * configuration.activationMultiplier)
        let releaseRMS = max(configuration.minimumActiveRMS * 0.6,
                             noiseFloorRMS * configuration.releaseMultiplier)
        if isActive {
            isActive = levels.rms >= releaseRMS
                && levels.peak >= configuration.minimumActivePeak * 0.5
        } else {
            isActive = levels.rms >= activationRMS
                && levels.peak >= configuration.minimumActivePeak
        }

        if !isActive {
            // Let the floor follow ordinary background changes, but cap one observation's upward
            // influence so a voice onset cannot immediately redefine itself as noise.
            let cappedRMS = min(levels.rms, max(configuration.minimumNoiseFloorRMS,
                                                noiseFloorRMS * 1.5))
            noiseFloorRMS += configuration.noiseAdaptationRate * (cappedRMS - noiseFloorRMS)
            noiseFloorRMS = max(configuration.minimumNoiseFloorRMS, noiseFloorRMS)
        }
        return Observation(sampleCount: levels.sampleCount, isActive: isActive)
    }

    private static func levels(in pcm16: Data) -> (sampleCount: Int, rms: Double, peak: Double) {
        pcm16.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count / 2
            guard count > 0 else { return (0, 0, 0) }
            var squaredSum = 0.0
            var peak = 0.0
            for index in 0..<count {
                let offset = index * 2
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let magnitude = abs(Double(Int16(bitPattern: bits)))
                squaredSum += magnitude * magnitude
                peak = max(peak, magnitude)
            }
            return (count, sqrt(squaredSum / Double(count)), peak)
        }
    }
}
