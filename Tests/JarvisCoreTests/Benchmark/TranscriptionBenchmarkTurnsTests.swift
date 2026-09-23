import Foundation
import Testing
@testable import JarvisCore

@Suite("Transcription benchmark turns")
struct TranscriptionBenchmarkTurnsTests {
    @Test("the turns matrix speaks twice on every selectable path")
    func turnsMatrixCoverage() {
        let arms = TranscriptionBenchmark.turnArms

        #expect(arms.count == OpenAITranscriptionModel.allCases.count + 1)
        #expect(arms.allSatisfy { $0.orderedPhrases.count == 2 })
        #expect(arms.allSatisfy { $0.orderedPhrases.allSatisfy { $0.language == .english } })
        #expect(Set(arms.compactMap(\.model)) == Set(OpenAITranscriptionModel.allCases))
        let apple = arms.filter { $0.provider == .appleSpeech }
        #expect(apple.count == 1)
        #expect(apple.first?.localeIdentifier == "en_US")
        // The standard matrix stays one phrase per session, so the follow-up costs it nothing.
        #expect(TranscriptionBenchmark.standardArms.count == 12)
        #expect(TranscriptionBenchmark.standardArms.allSatisfy { $0.followUpPhrase == nil })
    }

    @Test("both turns recognized in their own window pass")
    func bothTurnsRecognized() {
        let arm = appleArm
        let result = TranscriptionBenchmark.evaluateTurns(.init(
            arm: arm,
            turns: windows(arm),
            events: [
                event(.finalized, observedAt: 14, itemID: "one", text: arm.phrase.text),
                event(
                    .finalized,
                    observedAt: 34,
                    itemID: "two",
                    text: arm.followUpPhrase?.text),
            ],
            captureObservations: observations))

        let recognized = result.turns.map(\.recognized)
        let errorRates = result.turns.map(\.normalizedCharacterErrorRate)

        #expect(result.passed)
        #expect(result.turns.map(\.phraseID) == ["english-technical", "english-followup"])
        #expect(recognized == [true, true])
        #expect(errorRates == [0, 0])
        #expect(result.turns.first?.finalLatencySeconds == 2)
        #expect(result.turns.last?.finalLatencySeconds == 2)
        #expect(result.duplicateCount == 0)
    }

    @Test("a session that transcribes nothing after its first turn fails")
    func secondTurnLost() {
        let arm = appleArm
        let result = TranscriptionBenchmark.evaluateTurns(.init(
            arm: arm,
            turns: windows(arm),
            events: [
                event(.finalized, observedAt: 14, itemID: "one", text: arm.phrase.text),
            ],
            captureObservations: observations))

        #expect(result.passed == false)
        #expect(result.turns.first?.recognized == true)
        #expect(result.turns.last?.recognized == false)
        #expect(result.turns.last?.finalTexts.isEmpty == true)
        #expect(result.turns.last?.normalizedCharacterErrorRate == nil)
        #expect(result.failure == nil)
    }

    @Test("a mostly lost second turn fails even though text arrived")
    func secondTurnMostlyLost() {
        let arm = appleArm
        let result = TranscriptionBenchmark.evaluateTurns(.init(
            arm: arm,
            turns: windows(arm),
            events: [
                event(.finalized, observedAt: 14, itemID: "one", text: arm.phrase.text),
                event(.finalized, observedAt: 34, itemID: "two", text: "another"),
            ],
            captureObservations: observations))

        #expect(result.passed == false)
        #expect(result.turns.last?.recognized == false)
        #expect((result.turns.last?.normalizedCharacterErrorRate ?? 0) > 0.5)
    }

    @Test("repeating the first turn's text is not a second turn")
    func repeatedFirstTurn() {
        let arm = appleArm
        let result = TranscriptionBenchmark.evaluateTurns(.init(
            arm: arm,
            turns: windows(arm),
            events: [
                event(.finalized, observedAt: 14, itemID: "one", text: arm.phrase.text),
                event(.finalized, observedAt: 34, itemID: "two", text: arm.phrase.text),
            ],
            captureObservations: observations))

        #expect(result.passed == false)
        #expect(result.turns.last?.recognized == false)
        #expect(result.duplicateCount == 1)
    }

    @Test("fragments of one turn are joined inside that turn's window")
    func splitFragments() {
        let arm = appleArm
        let result = TranscriptionBenchmark.evaluateTurns(.init(
            arm: arm,
            turns: windows(arm),
            events: [
                event(.finalized, observedAt: 14, itemID: "one", text: arm.phrase.text),
                event(
                    .finalized,
                    observedAt: 33,
                    itemID: "two",
                    text: "Then the coach waits"),
                event(
                    .finalized,
                    observedAt: 34,
                    itemID: "three",
                    text: "until the speaker finishes another sentence."),
            ],
            captureObservations: observations))

        #expect(result.passed)
        #expect(result.turns.last?.finalTexts.count == 2)
        #expect(result.turns.last?.normalizedCharacterErrorRate == 0)
    }

    @Test("a reconnect or an unavailable final contaminates a turns arm")
    func contamination() {
        let arm = appleArm
        let reconnected = TranscriptionBenchmark.evaluateTurns(.init(
            arm: arm,
            turns: windows(arm),
            events: [
                event(.finalized, observedAt: 14, itemID: "one", text: arm.phrase.text),
                event(
                    .finalized,
                    observedAt: 34,
                    itemID: "two",
                    text: arm.followUpPhrase?.text),
            ],
            captureObservations: observations,
            connectionStates: [.reconnecting(attempt: 1)]))

        #expect(reconnected.passed == false)
        #expect(reconnected.failure?.contains("reconnected") == true)

        let unavailable = TranscriptionBenchmark.evaluateTurns(.init(
            arm: arm,
            turns: windows(arm),
            events: [
                event(.finalized, observedAt: 14, itemID: "one", text: arm.phrase.text),
                event(
                    .finalized,
                    observedAt: 34,
                    itemID: "two",
                    text: nil,
                    unavailable: true),
            ],
            captureObservations: observations))

        #expect(unavailable.passed == false)
        #expect(unavailable.unavailableCount == 1)
        #expect(unavailable.turns.last?.finalTexts.isEmpty == true)
    }

    @Test("an unavailable arm reports its reason without any turn")
    func unavailableArm() {
        let result = TranscriptionBenchmark.evaluateTurns(.init(
            arm: appleArm,
            turns: [],
            events: [],
            failure: "Apple Speech unavailable: requires macOS 26 or later"))

        #expect(result.passed == false)
        #expect(result.turns.isEmpty)
        #expect(result.failure?.contains("requires macOS 26") == true)
    }

    @Test("capture gaps fail a turns arm that transcribed correctly")
    func captureGap() {
        let arm = appleArm
        let result = TranscriptionBenchmark.evaluateTurns(.init(
            arm: arm,
            turns: windows(arm),
            events: [
                event(.finalized, observedAt: 14, itemID: "one", text: arm.phrase.text),
                event(
                    .finalized,
                    observedAt: 34,
                    itemID: "two",
                    text: arm.followUpPhrase?.text),
            ],
            captureObservations: [
                .init(sequenceNumber: 1, sampleCount: 2_400),
                .init(sequenceNumber: 3, sampleCount: 2_400),
            ]))

        #expect(result.turns.map(\.recognized) == [true, true])
        #expect(result.continuityPassed == false)
        #expect(result.passed == false)
    }

    @Test("a summary written before turns mode still decodes")
    func earlierSummaryDecodes() throws {
        let earlier = Data("""
        {
          "schemaVersion" : 1,
          "mode" : "standard",
          "repetitionsPerArm" : 3,
          "arms" : []
        }
        """.utf8)

        let summary = try JSONDecoder().decode(
            TranscriptionBenchmark.Summary.self,
            from: earlier)

        #expect(summary.turns.isEmpty)
        #expect(summary.reconnect.isEmpty)
        #expect(summary.armFilter == nil)
        #expect(summary.mode == "standard")
    }

    private var appleArm: TranscriptionBenchmark.Arm {
        TranscriptionBenchmark.turnArms.first { $0.provider == .appleSpeech }!
    }

    private var observations: [TranscriptionBenchmark.CaptureObservation] {
        [
            .init(sequenceNumber: 1, sampleCount: 2_400),
            .init(sequenceNumber: 2, sampleCount: 2_400),
        ]
    }

    private func windows(
        _ arm: TranscriptionBenchmark.Arm
    ) -> [TranscriptionBenchmark.TurnWindow] {
        [
            .init(phrase: arm.phrase, startedAt: 10, speechEndedAt: 12),
            .init(phrase: arm.followUpPhrase!, startedAt: 30, speechEndedAt: 32),
        ]
    }

    private func event(
        _ kind: TranscriptionBenchmarkEvent.Kind,
        observedAt: TimeInterval,
        itemID: String? = nil,
        text: String? = nil,
        unavailable: Bool = false
    ) -> TranscriptionBenchmarkEvent {
        TranscriptionBenchmarkEvent(
            kind: kind,
            provider: TranscriptionProvider.appleSpeech.rawValue,
            model: nil,
            speaker: Speaker.them.rawValue,
            generation: 1,
            itemID: itemID,
            text: text,
            spokenAt: nil,
            observedAt: observedAt,
            transcriptUnavailable: unavailable,
            replayedChunks: nil,
            evictedChunks: nil)
    }
}
