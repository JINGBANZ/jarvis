import Foundation

public extension TranscriptionBenchmark {
    struct RepetitionInput: Sendable {
        public let arm: Arm
        public let repetition: Int
        public let fixtureSHA256: String
        public let connectStartedAt: TimeInterval
        /// Nil when playback never started.
        public let speechStartedAt: TimeInterval?
        public let speechEndedAt: TimeInterval
        public let events: [TranscriptionBenchmarkEvent]
        public let captureObservations: [CaptureObservation]
        public let connectionStates: [TranscriptionConnectionState]
        public let failure: String?

        public init(
            arm: Arm,
            repetition: Int,
            fixtureSHA256: String,
            connectStartedAt: TimeInterval,
            speechStartedAt: TimeInterval? = nil,
            speechEndedAt: TimeInterval,
            events: [TranscriptionBenchmarkEvent],
            captureObservations: [CaptureObservation] = [],
            connectionStates: [TranscriptionConnectionState] = [],
            failure: String? = nil
        ) {
            self.arm = arm
            self.repetition = repetition
            self.fixtureSHA256 = fixtureSHA256
            self.connectStartedAt = connectStartedAt
            self.speechStartedAt = speechStartedAt
            self.speechEndedAt = speechEndedAt
            self.events = events
            self.captureObservations = captureObservations
            self.connectionStates = connectionStates
            self.failure = failure
        }
    }

    struct CaptureObservation: Equatable, Sendable {
        public let sequenceNumber: UInt64
        public let sampleCount: Int

        public init(sequenceNumber: UInt64, sampleCount: Int) {
            precondition(sampleCount >= 0)
            self.sequenceNumber = sequenceNumber
            self.sampleCount = sampleCount
        }
    }

    struct RepetitionResult: Codable, Equatable, Sendable {
        public let armID: String
        public let repetition: Int
        public let fixtureSHA256: String
        public let expectedText: String
        public let finalTexts: [String]
        public let finalItemIDs: [String]
        public let normalizedCharacterEditDistance: Int?
        public let normalizedCharacterErrorRate: Double?
        public let readinessLatencySeconds: TimeInterval?
        public let endpointLatencySeconds: TimeInterval?
        public let commitLatencySeconds: TimeInterval?
        public let finalLatencySeconds: TimeInterval?
        /// Earliest reported spoken start minus playback start. Fixture lead-in and provider padding
        /// shift every repetition alike, so the spread, not the value, is the timing jitter.
        public let spokenStartOffsetSeconds: TimeInterval?
        public let missing: Bool
        public let duplicateCount: Int
        public let providerDuplicateCount: Int
        public let revisionCount: Int
        public let unavailableCount: Int
        public let recoveredFromDeltasCount: Int
        public let finalHeardOrdering: [String]
        public let capturedChunkCount: Int
        public let capturedSampleCount: Int
        public let captureSequenceGapCount: Int
        public let evictedChunkCount: Int
        public let continuityPassed: Bool
        public let failure: String?
    }

    struct ArmSummary: Codable, Equatable, Sendable {
        public let arm: Arm
        public let repetitions: [RepetitionResult]
        public let unavailableReason: String?

        public init(arm: Arm, repetitions: [RepetitionResult], unavailableReason: String? = nil) {
            self.arm = arm
            self.repetitions = repetitions.sorted { $0.repetition < $1.repetition }
            self.unavailableReason = unavailableReason
        }
    }

    /// One spoken turn of a turns arm. The runner owns the boundaries because it owns playback:
    /// `startedAt` is when this turn's audio began and `speechEndedAt` is when it stopped, both on
    /// the run's clock, so a final is attributed by when it was observed rather than by matching
    /// text.
    struct TurnWindow: Sendable {
        public let phrase: Phrase
        public let startedAt: TimeInterval
        public let speechEndedAt: TimeInterval

        public init(phrase: Phrase, startedAt: TimeInterval, speechEndedAt: TimeInterval) {
            self.phrase = phrase
            self.startedAt = startedAt
            self.speechEndedAt = speechEndedAt
        }
    }

    struct TurnsInput: Sendable {
        public let arm: Arm
        public let turns: [TurnWindow]
        public let events: [TranscriptionBenchmarkEvent]
        public let captureObservations: [CaptureObservation]
        public let connectionStates: [TranscriptionConnectionState]
        public let failure: String?

        public init(
            arm: Arm,
            turns: [TurnWindow],
            events: [TranscriptionBenchmarkEvent],
            captureObservations: [CaptureObservation] = [],
            connectionStates: [TranscriptionConnectionState] = [],
            failure: String? = nil
        ) {
            self.arm = arm
            self.turns = turns
            self.events = events
            self.captureObservations = captureObservations
            self.connectionStates = connectionStates
            self.failure = failure
        }
    }

    struct TurnResult: Codable, Equatable, Sendable {
        public let phraseID: String
        public let expectedText: String
        public let finalTexts: [String]
        public let normalizedCharacterErrorRate: Double?
        public let finalLatencySeconds: TimeInterval?
        public let recognized: Bool
    }

    struct TurnsSummary: Codable, Equatable, Sendable {
        public let armID: String
        public let provider: TranscriptionProvider
        public let model: OpenAITranscriptionModel?
        public let localeIdentifier: String?
        public let turns: [TurnResult]
        public let duplicateCount: Int
        public let unavailableCount: Int
        public let capturedChunkCount: Int
        public let capturedSampleCount: Int
        public let captureSequenceGapCount: Int
        public let continuityPassed: Bool
        public let passed: Bool
        public let failure: String?
    }

    struct ReconnectSummary: Codable, Equatable, Sendable {
        public let model: OpenAITranscriptionModel
        public let phraseIDs: [String]
        public let finalTexts: [String]
        public let finalPhraseIDs: [String]
        public let replayedChunks: Int
        public let evictedChunks: Int
        public let readyGenerations: [Int]
        public let exactlyOnce: Bool
        public let ordered: Bool
        public let noFallback: Bool
        public let capturedChunkCount: Int
        public let capturedSampleCount: Int
        public let captureSequenceGapCount: Int
        public let continuityPassed: Bool
        public let passed: Bool
        public let failure: String?
    }

    struct Summary: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let mode: String
        public let repetitionsPerArm: Int
        /// Present only on a filtered run, so a partial matrix is never read as the whole one.
        public let armFilter: String?
        public let arms: [ArmSummary]
        public let reconnect: [ReconnectSummary]
        public let turns: [TurnsSummary]

        public init(
            mode: String,
            repetitionsPerArm: Int,
            armFilter: String? = nil,
            arms: [ArmSummary],
            reconnect: [ReconnectSummary] = [],
            turns: [TurnsSummary] = []
        ) {
            schemaVersion = TranscriptionBenchmark.schemaVersion
            self.mode = mode
            self.repetitionsPerArm = repetitionsPerArm
            self.armFilter = armFilter
            self.arms = arms.sorted { $0.arm.id < $1.arm.id }
            self.reconnect = reconnect.sorted { $0.model.rawValue < $1.model.rawValue }
            self.turns = turns.sorted { $0.armID < $1.armID }
        }

        public func encodedJSON() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        }
    }
}
