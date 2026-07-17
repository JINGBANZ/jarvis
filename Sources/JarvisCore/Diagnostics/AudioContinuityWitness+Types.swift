import Foundation

extension AudioContinuityWitness {
    public struct ActivityConfiguration: Equatable, Sendable {
        public let initialNoiseFloorRMS: Double
        public let minimumNoiseFloorRMS: Double
        public let minimumActiveRMS: Double
        public let minimumActivePeak: Double
        public let activationMultiplier: Double
        public let releaseMultiplier: Double
        public let noiseAdaptationRate: Double

        public init(initialNoiseFloorRMS: Double = 80,
                    minimumNoiseFloorRMS: Double = 20,
                    minimumActiveRMS: Double = 220,
                    minimumActivePeak: Double = 600,
                    activationMultiplier: Double = 3,
                    releaseMultiplier: Double = 1.6,
                    noiseAdaptationRate: Double = 0.05) {
            precondition(initialNoiseFloorRMS >= minimumNoiseFloorRMS)
            precondition(minimumNoiseFloorRMS >= 0 && minimumActiveRMS > 0 && minimumActivePeak > 0)
            precondition(activationMultiplier > releaseMultiplier && releaseMultiplier > 0)
            precondition((0...1).contains(noiseAdaptationRate))
            self.initialNoiseFloorRMS = initialNoiseFloorRMS
            self.minimumNoiseFloorRMS = minimumNoiseFloorRMS
            self.minimumActiveRMS = minimumActiveRMS
            self.minimumActivePeak = minimumActivePeak
            self.activationMultiplier = activationMultiplier
            self.releaseMultiplier = releaseMultiplier
            self.noiseAdaptationRate = noiseAdaptationRate
        }
    }

    public struct Configuration: Equatable, Sendable {
        public let snapshotInterval: TimeInterval
        public let captureStallThreshold: TimeInterval
        public let deliveryLagThreshold: TimeInterval
        public let sustainedActivityDuration: TimeInterval
        public let activityHangover: TimeInterval
        public let serverSpeechGrace: TimeInterval
        public let maximumPendingCaptures: Int
        public let activity: ActivityConfiguration

        public init(snapshotInterval: TimeInterval = 15,
                    captureStallThreshold: TimeInterval = 2,
                    deliveryLagThreshold: TimeInterval = 0.25,
                    sustainedActivityDuration: TimeInterval = 0.75,
                    activityHangover: TimeInterval = 0.5,
                    serverSpeechGrace: TimeInterval = 3,
                    maximumPendingCaptures: Int = 4_096,
                    activity: ActivityConfiguration = .init()) {
            precondition(snapshotInterval > 0 && captureStallThreshold > 0)
            precondition(deliveryLagThreshold > 0 && sustainedActivityDuration >= 0)
            precondition(activityHangover >= 0 && serverSpeechGrace >= 0
                         && maximumPendingCaptures > 0)
            self.snapshotInterval = snapshotInterval
            self.captureStallThreshold = captureStallThreshold
            self.deliveryLagThreshold = deliveryLagThreshold
            self.sustainedActivityDuration = sustainedActivityDuration
            self.activityHangover = activityHangover
            self.serverSpeechGrace = serverSpeechGrace
            self.maximumPendingCaptures = maximumPendingCaptures
            self.activity = activity
        }
    }

    public enum ServerSpeechSignal: Equatable, Sendable {
        case speechStarted
        case speechStopped
        case transcriptionDelta
        case transcriptionCompleted
        case transcriptionFailed
    }

    public enum SequenceStage: Equatable, Sendable {
        case capture
        case delivery
    }

    public enum Anomaly: Equatable, Sendable {
        case captureStalled(lastCaptureAt: TimeInterval?, duration: TimeInterval)
        case sequenceGap(stage: SequenceStage, expected: UInt64, observed: UInt64)
        case deliveryWithoutCapture(sequence: UInt64)
        case deliverySampleCountMismatch(sequence: UInt64, captured: Int, delivered: Int)
        case captureToDeliveryLag(sequence: UInt64, lag: TimeInterval)
        case reconnectBufferOverflow(evictedChunks: Int, firstSequence: UInt64?,
                                     lastSequence: UInt64?)
        case localActivityUnmatched(activeSince: TimeInterval, duration: TimeInterval)
        case serverSpeechObservedAfterUnmatchedActivity(activeSince: TimeInterval,
                                                        serverObservedAt: TimeInterval)
    }

    public struct SocketGenerationSnapshot: Equatable, Sendable {
        public let generation: Int
        public let sendAttempts: Int
        public let sendSuccesses: Int
        public let sendFailures: Int
        public let lastSendSequence: UInt64?
        public let lastSendAttemptAt: TimeInterval?
        public let lastSendSuccessAt: TimeInterval?
        public let lastSendFailureAt: TimeInterval?
        public let serverSpeechSignals: Int
        public let lastServerSignal: ServerSpeechSignal?
        public let lastServerObservedAt: TimeInterval?
        public let lastServerAudioTimeMilliseconds: Int?
    }

    public struct Snapshot: Equatable, Sendable {
        public let emittedAt: TimeInterval
        public let capturedChunks: Int
        public let capturedSamples: Int
        public let deliveredChunks: Int
        public let deliveredSamples: Int
        public let lastCapturedSequence: UInt64?
        public let lastDeliveredSequence: UInt64?
        public let lastCaptureAt: TimeInterval?
        public let lastDeliveryAt: TimeInterval?
        public let pendingCapturedChunks: Int
        public let localActivityDetected: Bool
        public let localActivitySince: TimeInterval?
        public let lastLocalActivityAt: TimeInterval?
        public let latestSocketGeneration: Int?
        public let socketGenerations: [SocketGenerationSnapshot]
    }

    public struct Output: Equatable, Sendable {
        public let snapshot: Snapshot?
        public let anomalies: [Anomaly]
    }
}
