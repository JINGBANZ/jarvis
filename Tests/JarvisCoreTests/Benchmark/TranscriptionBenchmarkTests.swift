import Foundation
import Testing
@testable import JarvisCore

@Suite("Transcription benchmark")
struct TranscriptionBenchmarkTests {
    @Test("standard plan covers every provider path and fixed language phrase")
    func standardPlanCoverage() {
        let arms = TranscriptionBenchmark.standardArms

        #expect(arms.count == 12)
        for model in OpenAITranscriptionModel.allCases {
            let modelArms = arms.filter { $0.model == model }
            #expect(Set(modelArms.map(\.phrase.language)) == Set(TranscriptionBenchmark.Language.allCases))
        }
        let appleArms = arms.filter { $0.provider == .appleSpeech }
        #expect(Set(appleArms.map(\.phrase.language)) == Set(TranscriptionBenchmark.Language.allCases))
        #expect(appleArms.first { $0.phrase.language == .english }?.localeIdentifier == "en_US")
        #expect(appleArms.first { $0.phrase.language == .mandarin }?.localeIdentifier == "zh_CN")
        #expect(appleArms.first { $0.phrase.language == .bilingual }?.localeIdentifier == "zh_CN")
    }

    @Test("evaluation measures distinct lifecycle boundaries and quality")
    func lifecycleBoundaries() {
        let arm = TranscriptionBenchmark.standardArms.first {
            $0.model == .gptTranscribe && $0.phrase.language == .english
        }!
        let input = TranscriptionBenchmark.RepetitionInput(
            arm: arm,
            repetition: 2,
            fixtureSHA256: "abc123",
            connectStartedAt: 10,
            speechEndedAt: 20,
            events: [
                event(.ready, observedAt: 11, model: arm.model?.rawValue),
                event(.clientCommit, observedAt: 20.2, model: arm.model?.rawValue),
                event(
                    .finalized,
                    observedAt: 21.5,
                    model: arm.model?.rawValue,
                    itemID: "item-1",
                    text: arm.phrase.text,
                    spokenAt: 12),
            ],
            captureObservations: [
                .init(sequenceNumber: 7, sampleCount: 2_400),
                .init(sequenceNumber: 8, sampleCount: 2_400),
            ])

        let result = TranscriptionBenchmark.evaluate(input)

        #expect(result.readinessLatencySeconds == 1)
        #expect(result.endpointLatencySeconds == nil)
        #expect(abs((result.commitLatencySeconds ?? 0) - 0.2) < 0.000_001)
        #expect(result.finalLatencySeconds == 1.5)
        #expect(result.normalizedCharacterEditDistance == 0)
        #expect(result.normalizedCharacterErrorRate == 0)
        #expect(result.missing == false)
        #expect(result.finalHeardOrdering == [arm.phrase.text])
        #expect(result.capturedChunkCount == 2)
        #expect(result.capturedSampleCount == 4_800)
        #expect(result.captureSequenceGapCount == 0)
        #expect(result.evictedChunkCount == 0)
        #expect(result.continuityPassed)
    }

    @Test("split finalized fragments are not duplicate deliveries")
    func splitFragments() {
        let arm = TranscriptionBenchmark.standardArms.first {
            $0.model == .gpt4oTranscribe && $0.phrase.language == .english
        }!
        let result = TranscriptionBenchmark.evaluate(.init(
            arm: arm,
            repetition: 1,
            fixtureSHA256: "hash",
            connectStartedAt: 1,
            speechEndedAt: 3,
            events: [
                event(
                    .finalized,
                    observedAt: 4,
                    model: arm.model?.rawValue,
                    itemID: "fragment-1",
                    text: "The actor preserves ordered audio"),
                event(
                    .finalized,
                    observedAt: 4.1,
                    model: arm.model?.rawValue,
                    itemID: "fragment-2",
                    text: "while the socket reconnects."),
            ]))

        #expect(result.normalizedCharacterEditDistance == 0)
        #expect(result.duplicateCount == 0)
        #expect(result.finalTexts.count == 2)
    }

    @Test("a reconnect contaminates a standard repetition")
    func standardReconnectIsFailure() {
        let arm = TranscriptionBenchmark.standardArms.first {
            $0.model == .gptTranscribe && $0.phrase.language == .english
        }!
        let result = TranscriptionBenchmark.evaluate(.init(
            arm: arm,
            repetition: 1,
            fixtureSHA256: "hash",
            connectStartedAt: 1,
            speechEndedAt: 3,
            events: [
                event(
                    .finalized,
                    observedAt: 4,
                    model: arm.model?.rawValue,
                    itemID: "final",
                    text: arm.phrase.text),
            ],
            connectionStates: [.ready, .reconnecting(attempt: 1), .ready]))

        #expect(result.failure ==
            "Transcription reconnected during a standard benchmark repetition")
    }

    @Test("evaluation reports missing unavailable duplicate and revised finals")
    func anomalies() {
        let arm = TranscriptionBenchmark.standardArms.first {
            $0.model == .gpt4oTranscribe && $0.phrase.language == .mandarin
        }!
        let events = [
            event(.serverEndpoint, observedAt: 3.1, model: arm.model?.rawValue, itemID: "one"),
            event(
                .providerFinal,
                observedAt: 3.15,
                model: arm.model?.rawValue,
                itemID: "one",
                text: "系统在网络恢复后按顺序提交音频"),
            event(
                .providerFinal,
                observedAt: 3.16,
                model: arm.model?.rawValue,
                itemID: "one",
                text: "系统在网络恢复后按顺序发送音频"),
            event(
                .providerFinal,
                observedAt: 3.17,
                model: arm.model?.rawValue,
                itemID: "replay",
                text: "系统在网络恢复后按顺序发送音频"),
            event(
                .finalized,
                observedAt: 3.2,
                model: arm.model?.rawValue,
                itemID: "one",
                text: "系统在网络恢复后按顺序提交音频"),
            event(
                .finalized,
                observedAt: 3.3,
                model: arm.model?.rawValue,
                itemID: "one",
                text: "系统在网络恢复后按顺序提交音频。"),
            event(
                .finalized,
                observedAt: 3.4,
                model: arm.model?.rawValue,
                itemID: "two",
                unavailable: true),
            event(
                .providerFinal,
                observedAt: 3.41,
                model: arm.model?.rawValue,
                itemID: "two",
                unavailable: true),
        ]

        let result = TranscriptionBenchmark.evaluate(.init(
            arm: arm,
            repetition: 1,
            fixtureSHA256: "hash",
            connectStartedAt: 1,
            speechEndedAt: 3,
            events: events))

        #expect(result.missing == false)
        #expect(result.duplicateCount == 1)
        #expect(result.providerDuplicateCount == 1)
        #expect(result.revisionCount == 1)
        #expect(result.unavailableCount == 1)
        #expect(abs((result.endpointLatencySeconds ?? 0) - 0.1) < 0.000_001)
        #expect(abs((result.finalLatencySeconds ?? 0) - 0.4) < 0.000_001)
    }

    @Test("rejected provider final is counted as unavailable")
    func unavailableAfterEmptyCompletion() {
        let arm = TranscriptionBenchmark.standardArms.first {
            $0.model == .gpt4oTranscribe && $0.phrase.language == .english
        }!
        let result = TranscriptionBenchmark.evaluate(.init(
            arm: arm,
            repetition: 1,
            fixtureSHA256: "hash",
            connectStartedAt: 1,
            speechEndedAt: 3,
            events: [
                event(
                    .providerFinal,
                    observedAt: 3.1,
                    model: arm.model?.rawValue,
                    itemID: "empty",
                    text: " … ",
                    unavailable: true),
                event(
                    .finalized,
                    observedAt: 3.2,
                    model: arm.model?.rawValue,
                    itemID: "empty",
                    unavailable: true),
            ]))

        #expect(result.missing)
        #expect(result.unavailableCount == 1)
        #expect(abs((result.finalLatencySeconds ?? 0) - 0.2) < 0.000_001)
    }

    @Test("normalization and edit distance are Unicode aware")
    func normalizationAndDistance() {
        #expect(TranscriptionBenchmark.normalize(" Swift, ACTOR! ") == "swiftactor")
        #expect(TranscriptionBenchmark.normalize("网络，恢复！") == "网络恢复")
        #expect(TranscriptionBenchmark.editDistance("kitten", "sitting") == 3)
    }

    @Test("summary JSON is stable regardless of input arm order")
    func deterministicJSON() throws {
        let arms = Array(TranscriptionBenchmark.standardArms.prefix(2))
        let summaries = arms.map { TranscriptionBenchmark.ArmSummary(arm: $0, repetitions: []) }
        let forward = try TranscriptionBenchmark.Summary(
            mode: "standard", repetitionsPerArm: 3, arms: summaries).encodedJSON()
        let reverse = try TranscriptionBenchmark.Summary(
            mode: "standard", repetitionsPerArm: 3, arms: summaries.reversed()).encodedJSON()

        #expect(forward == reverse)
        let object = try #require(JSONSerialization.jsonObject(with: forward) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
    }

    @Test("reconnect evaluation requires replay exactly once ordering and provider identity")
    func reconnectAcceptance() {
        let model = OpenAITranscriptionModel.gptLiveTranscribe
        let expected = ["english-technical", "mandarin-technical"]
        let phrases = expected.map { id in
            TranscriptionBenchmark.phrases.first { $0.id == id }!
        }
        let events = [
            event(.ready, observedAt: 1, model: model.rawValue, generation: 1),
            event(
                .reconnectPrepared,
                observedAt: 2,
                model: model.rawValue,
                generation: 1,
                replayedChunks: 4),
            event(
                .ready,
                observedAt: 5,
                model: model.rawValue,
                generation: 2,
                replayedChunks: 40),
            event(
                .finalized,
                observedAt: 6,
                model: model.rawValue,
                itemID: "english",
                text: phrases[0].text,
                spokenAt: 3,
                generation: 2),
            event(
                .finalized,
                observedAt: 7,
                model: model.rawValue,
                itemID: "mandarin",
                text: phrases[1].text,
                spokenAt: 4,
                generation: 2),
        ]

        let result = TranscriptionBenchmark.evaluateReconnect(
            model: model,
            phraseIDs: expected,
            events: events,
            captureObservations: [
                .init(sequenceNumber: 20, sampleCount: 2_400),
                .init(sequenceNumber: 21, sampleCount: 2_400),
            ])

        #expect(result.passed)
        #expect(result.exactlyOnce)
        #expect(result.ordered)
        #expect(result.noFallback)
        #expect(result.readyGenerations == [1, 2])
        #expect(result.replayedChunks == 40)
        #expect(result.evictedChunks == 0)
        #expect(result.continuityPassed)
        #expect(result.finalTexts == phrases.map(\.text))
        #expect(result.finalPhraseIDs == expected)
    }

    @Test("reconnect evaluation reconstructs phrases split across finalized items")
    func reconnectAcceptanceWithSegmentedFinals() {
        let model = OpenAITranscriptionModel.gptLiveTranscribe
        let expected = ["english-technical", "mandarin-technical"]
        let events = [
            event(.ready, observedAt: 1, model: model.rawValue, generation: 1),
            event(
                .ready,
                observedAt: 2,
                model: model.rawValue,
                generation: 2,
                replayedChunks: 40),
            event(
                .finalized,
                observedAt: 3,
                model: model.rawValue,
                itemID: "english-one",
                text: "The actor preserves ordered audio",
                spokenAt: 3,
                generation: 2),
            event(
                .finalized,
                observedAt: 4,
                model: model.rawValue,
                itemID: "english-two",
                text: "while the socket reconnects.",
                spokenAt: 3.1,
                generation: 2),
            event(
                .finalized,
                observedAt: 5,
                model: model.rawValue,
                itemID: "mandarin-one",
                text: "系统在网络恢复后",
                spokenAt: 4,
                generation: 2),
            event(
                .finalized,
                observedAt: 6,
                model: model.rawValue,
                itemID: "mandarin-two",
                text: "按顺序提交音频。",
                spokenAt: 4.1,
                generation: 2),
        ]

        let result = TranscriptionBenchmark.evaluateReconnect(
            model: model,
            phraseIDs: expected,
            events: events,
            captureObservations: [
                .init(sequenceNumber: 20, sampleCount: 2_400),
                .init(sequenceNumber: 21, sampleCount: 2_400),
            ])

        #expect(result.passed)
        #expect(result.exactlyOnce)
        #expect(result.ordered)
        #expect(result.finalTexts.count == 4)
        #expect(result.finalPhraseIDs == expected)
        #expect(TranscriptionBenchmark.recognizedReconnectPhraseIDs(
            expected,
            in: events,
            generation: 2
        ) == expected)
    }

    @Test("reconnect recognition waits past duplicate and unavailable finals for every phrase")
    func reconnectPhraseRecognition() {
        let model = OpenAITranscriptionModel.gpt4oTranscribe
        let expected = ["english-technical", "mandarin-technical"]
        let phrases = expected.map { id in
            TranscriptionBenchmark.phrases.first { $0.id == id }!
        }
        var events = [
            event(.ready, observedAt: 1, model: model.rawValue, generation: 1),
            event(.ready, observedAt: 2, model: model.rawValue, generation: 2),
            event(
                .finalized,
                observedAt: 3,
                model: model.rawValue,
                itemID: "english-one",
                text: phrases[0].text,
                generation: 2),
            event(
                .finalized,
                observedAt: 4,
                model: model.rawValue,
                itemID: "unavailable",
                unavailable: true,
                generation: 2),
            event(
                .finalized,
                observedAt: 5,
                model: model.rawValue,
                itemID: "english-two",
                text: phrases[0].text,
                generation: 2),
        ]

        #expect(TranscriptionBenchmark.recognizedReconnectPhraseIDs(
            expected,
            in: events,
            generation: 2
        ) == [expected[0], expected[0]])

        events.append(event(
            .finalized,
            observedAt: 6,
            model: model.rawValue,
            itemID: "mandarin",
            text: phrases[1].text,
            generation: 2))
        #expect(Set(TranscriptionBenchmark.recognizedReconnectPhraseIDs(
            expected,
            in: events,
            generation: 2
        )) == Set(expected))
    }

    @Test("reconnect evaluation cannot combine finals from multiple replacement generations")
    func reconnectRejectsCrossGenerationPhrases() {
        let model = OpenAITranscriptionModel.gpt4oTranscribe
        let expected = ["english-technical", "mandarin-technical"]
        let phrases = expected.map { id in
            TranscriptionBenchmark.phrases.first { $0.id == id }!
        }
        let events = [
            event(.ready, observedAt: 1, model: model.rawValue, generation: 1),
            event(
                .ready,
                observedAt: 2,
                model: model.rawValue,
                generation: 2,
                replayedChunks: 10),
            event(
                .finalized,
                observedAt: 3,
                model: model.rawValue,
                text: phrases[0].text,
                generation: 2),
            event(
                .ready,
                observedAt: 4,
                model: model.rawValue,
                generation: 3,
                replayedChunks: 10),
            event(
                .finalized,
                observedAt: 5,
                model: model.rawValue,
                text: phrases[1].text,
                generation: 3),
        ]

        let result = TranscriptionBenchmark.evaluateReconnect(
            model: model,
            phraseIDs: expected,
            events: events,
            captureObservations: [.init(sequenceNumber: 1, sampleCount: 2_400)])

        #expect(!result.passed)
        #expect(!result.exactlyOnce)
        #expect(result.finalPhraseIDs == [expected[0]])
        #expect(result.readyGenerations == [1, 2, 3])
    }

    @Test("reconnect evaluation rejects an unrelated extra final")
    func reconnectRejectsExtraFinal() {
        let model = OpenAITranscriptionModel.gpt4oTranscribe
        let expected = ["english-technical", "mandarin-technical"]
        let phrases = expected.map { id in
            TranscriptionBenchmark.phrases.first { $0.id == id }!
        }
        let events = [
            event(.ready, observedAt: 1, model: model.rawValue, generation: 1),
            event(
                .ready,
                observedAt: 2,
                model: model.rawValue,
                generation: 2,
                replayedChunks: 10),
            event(
                .finalized,
                observedAt: 3,
                model: model.rawValue,
                text: phrases[0].text,
                generation: 2),
            event(
                .finalized,
                observedAt: 4,
                model: model.rawValue,
                text: phrases[1].text,
                generation: 2),
            event(
                .finalized,
                observedAt: 5,
                model: model.rawValue,
                text: "Unrelated extra transcript.",
                generation: 2),
        ]

        let result = TranscriptionBenchmark.evaluateReconnect(
            model: model,
            phraseIDs: expected,
            events: events,
            captureObservations: [.init(sequenceNumber: 1, sampleCount: 2_400)])

        #expect(!result.passed)
        #expect(!result.exactlyOnce)
        #expect(result.finalTexts.count == 3)
        #expect(result.finalPhraseIDs == expected)
    }

    @Test("reconnect evaluation rejects duplicate replay and model fallback")
    func reconnectRejection() {
        let model = OpenAITranscriptionModel.gpt4oTranscribe
        let phrase = TranscriptionBenchmark.phrases.first { $0.id == "english-technical" }!
        let events = [
            event(.ready, observedAt: 1, model: model.rawValue, generation: 1),
            event(
                .ready,
                observedAt: 2,
                model: OpenAITranscriptionModel.gptTranscribe.rawValue,
                generation: 2,
                replayedChunks: 10),
            event(
                .bufferEviction,
                observedAt: 2.1,
                model: model.rawValue,
                generation: 2,
                evictedChunks: 1),
            event(
                .finalized,
                observedAt: 3,
                model: model.rawValue,
                itemID: "one",
                text: phrase.text,
                spokenAt: 2.5,
                generation: 2),
            event(
                .finalized,
                observedAt: 4,
                model: model.rawValue,
                itemID: "duplicate",
                text: phrase.text,
                spokenAt: 2.6,
                generation: 2),
        ]

        let result = TranscriptionBenchmark.evaluateReconnect(
            model: model,
            phraseIDs: [phrase.id],
            events: events,
            captureObservations: [
                .init(sequenceNumber: 20, sampleCount: 2_400),
                .init(sequenceNumber: 22, sampleCount: 2_400),
            ])

        #expect(result.passed == false)
        #expect(result.exactlyOnce == false)
        #expect(result.noFallback == false)
        #expect(result.evictedChunks == 1)
        #expect(result.captureSequenceGapCount == 1)
        #expect(result.continuityPassed == false)
        #expect(result.failure != nil)
    }

    @Test("reconnect evaluation rejects unrelated finals and stale-generation text")
    func reconnectRejectsUnrecognizedOrStaleText() {
        let model = OpenAITranscriptionModel.gptLiveTranscribe
        let phrase = TranscriptionBenchmark.phrases.first { $0.id == "english-technical" }!
        let events = [
            event(.ready, observedAt: 1, model: model.rawValue, generation: 1),
            event(
                .finalized,
                observedAt: 1.5,
                model: model.rawValue,
                itemID: "stale",
                text: phrase.text,
                generation: 1),
            event(
                .ready,
                observedAt: 2,
                model: model.rawValue,
                generation: 2,
                replayedChunks: 10),
            event(
                .finalized,
                observedAt: 3,
                model: model.rawValue,
                itemID: "unrelated",
                text: "Completely unrelated output that does not identify the outage phrase.",
                generation: 2),
        ]

        let result = TranscriptionBenchmark.evaluateReconnect(
            model: model,
            phraseIDs: [phrase.id],
            events: events,
            captureObservations: [.init(sequenceNumber: 1, sampleCount: 2_400)])

        #expect(result.passed == false)
        #expect(result.exactlyOnce == false)
        #expect(result.finalPhraseIDs.isEmpty)
        #expect(result.finalTexts.count == 1)
    }

    private func event(
        _ kind: TranscriptionDiagnosticEvent.Kind,
        observedAt: TimeInterval,
        model: String?,
        itemID: String? = nil,
        text: String? = nil,
        spokenAt: TimeInterval? = nil,
        unavailable: Bool = false,
        generation: Int = 1,
        replayedChunks: Int? = nil,
        evictedChunks: Int? = nil
    ) -> TranscriptionDiagnosticEvent {
        TranscriptionDiagnosticEvent(
            kind: kind,
            provider: TranscriptionProvider.openAI.rawValue,
            model: model,
            speaker: Speaker.them.rawValue,
            generation: generation,
            itemID: itemID,
            text: text,
            spokenAt: spokenAt,
            observedAt: observedAt,
            transcriptUnavailable: unavailable,
            replayedChunks: replayedChunks,
            evictedChunks: evictedChunks)
    }
}
