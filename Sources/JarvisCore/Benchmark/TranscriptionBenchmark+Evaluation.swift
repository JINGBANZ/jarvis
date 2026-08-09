import Foundation

public extension TranscriptionBenchmark {
    static func evaluate(_ input: RepetitionInput) -> RepetitionResult {
        let orderedEvents = input.events.enumerated().sorted {
            $0.element.observedAt != $1.element.observedAt
                ? $0.element.observedAt < $1.element.observedAt
                : $0.offset < $1.offset
        }.map(\.element)
        let ready = orderedEvents.first { $0.kind == .ready }
        let endpoints = orderedEvents.filter { $0.kind == .serverEndpoint }
        let commits = orderedEvents.filter { $0.kind == .clientCommit }
        let finals = orderedEvents.filter { $0.kind == .finalized }
        let providerFinals = orderedEvents.filter { $0.kind == .providerFinal }
        let bufferEvictions = orderedEvents.filter { $0.kind == .bufferEviction }
        let usableFinals = finals.filter { event in
            event.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let finalTexts = usableFinals.compactMap(\.text)
        let finalItemIDs = usableFinals.compactMap(\.itemID)
        let expected = normalize(input.arm.phrase.text)
        let actual = normalize(finalTexts.joined(separator: " "))
        let distance = actual.isEmpty ? nil : editDistance(expected, actual)
        let rate = distance.map { expected.isEmpty ? 0 : Double($0) / Double(expected.count) }

        let providerUsableFinals = providerFinals.filter {
            $0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let rawFinalsForRevision = providerFinals.isEmpty ? usableFinals : providerUsableFinals
        var textsByItem: [String: Set<String>] = [:]
        for final in rawFinalsForRevision {
            guard let itemID = final.itemID, let text = final.text else { continue }
            textsByItem[itemID, default: []].insert(normalize(text))
        }
        let revisionCount = textsByItem.values.reduce(0) { $0 + max(0, $1.count - 1) }
        // One repetition plays exactly one fixture. More than one accepted final is a duplicate
        // delivery from the benchmark's perspective, whether the provider reused or replaced its
        // item ID during replay.
        let duplicateCount = max(0, usableFinals.count - 1)
        let providerDuplicateCount = max(
            0,
            rawFinalsForRevision.count
                - Set(rawFinalsForRevision.compactMap(\.text).map(normalize)).count)
        let captureSequenceGapCount = sequenceGapCount(input.captureObservations)
        let capturedSampleCount = input.captureObservations.reduce(0) { $0 + $1.sampleCount }
        let evictedChunkCount = bufferEvictions.compactMap(\.evictedChunks).reduce(0, +)
        let unavailableEvents = orderedEvents.filter {
            ($0.kind == .providerFinal || $0.kind == .finalized)
                && $0.transcriptUnavailable
        }
        let unavailableItemIDs = Set(unavailableEvents.compactMap(\.itemID))
        let unavailableWithoutItemID = unavailableEvents.count(where: { $0.itemID == nil })

        return RepetitionResult(
            armID: input.arm.id,
            repetition: input.repetition,
            fixtureSHA256: input.fixtureSHA256,
            expectedText: input.arm.phrase.text,
            finalTexts: finalTexts,
            finalItemIDs: finalItemIDs,
            normalizedCharacterEditDistance: distance,
            normalizedCharacterErrorRate: rate,
            readinessLatencySeconds: ready.map { max(0, $0.observedAt - input.connectStartedAt) },
            endpointLatencySeconds: endpoints.first.map {
                max(0, $0.observedAt - input.speechEndedAt)
            },
            commitLatencySeconds: commits.first.map {
                max(0, $0.observedAt - input.speechEndedAt)
            },
            finalLatencySeconds: finals.last.map {
                max(0, $0.observedAt - input.speechEndedAt)
            },
            missing: usableFinals.isEmpty,
            duplicateCount: duplicateCount,
            providerDuplicateCount: providerDuplicateCount,
            revisionCount: revisionCount,
            unavailableCount: unavailableItemIDs.count + unavailableWithoutItemID,
            recoveredFromDeltasCount: finals.count(where: \.recoveredFromDeltas),
            finalHeardOrdering: usableFinals.sorted {
                ($0.spokenAt ?? $0.observedAt) < ($1.spokenAt ?? $1.observedAt)
            }.compactMap(\.text),
            capturedChunkCount: input.captureObservations.count,
            capturedSampleCount: capturedSampleCount,
            captureSequenceGapCount: captureSequenceGapCount,
            evictedChunkCount: evictedChunkCount,
            continuityPassed: !input.captureObservations.isEmpty
                && capturedSampleCount > 0
                && captureSequenceGapCount == 0
                && evictedChunkCount == 0,
            failure: input.failure)
    }

    static func evaluateReconnect(
        model: OpenAITranscriptionModel,
        phraseIDs: [String],
        events: [TranscriptionDiagnosticEvent],
        captureObservations: [CaptureObservation] = [],
        failure: String? = nil
    ) -> ReconnectSummary {
        let readyEvents = events.filter { $0.kind == .ready }.sorted {
            $0.observedAt < $1.observedAt
        }
        let initialGeneration = readyEvents.first?.generation
        let finals = initialGeneration.map {
            reconnectFinals(in: events, afterGeneration: $0)
        } ?? []
        let finalTexts = finals.compactMap(\.text)
        let finalPhraseIDs = initialGeneration.map {
            recognizedReconnectPhraseIDs(
                phraseIDs,
                in: events,
                afterGeneration: $0)
        } ?? []
        let exactlyOnce = phraseIDs.allSatisfy { expected in
            finalPhraseIDs.count(where: { $0 == expected }) == 1
        } && finalPhraseIDs.count == phraseIDs.count
        let ordered = finalPhraseIDs == phraseIDs
        let noFallback = !readyEvents.isEmpty && readyEvents.allSatisfy {
            $0.provider == TranscriptionProvider.openAI.rawValue
                && $0.model == model.rawValue
        }
        let readyGenerations = Array(Set(readyEvents.map(\.generation))).sorted()
        let replayEvents = events.filter {
            $0.kind == .reconnectPrepared || $0.kind == .ready
        }
        let replayedChunks = replayEvents.compactMap(\.replayedChunks).max() ?? 0
        let bufferEvictionEvents = events.filter { $0.kind == .bufferEviction }
        let evictedChunks = bufferEvictionEvents.isEmpty
            ? replayEvents.compactMap(\.evictedChunks).reduce(0, +)
            : bufferEvictionEvents.compactMap(\.evictedChunks).reduce(0, +)
        let captureSequenceGapCount = sequenceGapCount(captureObservations)
        let capturedSampleCount = captureObservations.reduce(0) { $0 + $1.sampleCount }
        let continuityPassed = !captureObservations.isEmpty
            && capturedSampleCount > 0
            && captureSequenceGapCount == 0
            && replayedChunks > 0
            && evictedChunks == 0
        let passed = failure == nil
            && readyGenerations.count >= 2
            && exactlyOnce
            && ordered
            && noFallback
            && continuityPassed
        return ReconnectSummary(
            model: model,
            phraseIDs: phraseIDs,
            finalTexts: finalTexts,
            finalPhraseIDs: finalPhraseIDs,
            replayedChunks: replayedChunks,
            evictedChunks: evictedChunks,
            readyGenerations: readyGenerations,
            exactlyOnce: exactlyOnce,
            ordered: ordered,
            noFallback: noFallback,
            capturedChunkCount: captureObservations.count,
            capturedSampleCount: capturedSampleCount,
            captureSequenceGapCount: captureSequenceGapCount,
            continuityPassed: continuityPassed,
            passed: passed,
            failure: failure ?? (passed ? nil : "Reconnect acceptance criteria were not met"))
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)))
            }
            previous = current
        }
        return previous[right.count]
    }

    /// Returns the fixed reconnect phrases recognized by replacement-generation final events, in
    /// spoken order. Both the live waiter and final evaluator use this function so extra,
    /// unavailable, or duplicate finals cannot make the runner stop before every expected phrase.
    static func recognizedReconnectPhraseIDs(
        _ phraseIDs: [String],
        in events: [TranscriptionDiagnosticEvent],
        afterGeneration generation: Int
    ) -> [String] {
        let expectedPhrases = phraseIDs.compactMap { id in
            phrases.first { $0.id == id }
        }
        return reconnectFinals(in: events, afterGeneration: generation).compactMap { event in
            guard let text = event.text else { return nil }
            return recognizedPhraseID(for: text, among: expectedPhrases)
        }
    }

    /// Reconnect verification is about recognizing the fixed outage phrases, not merely receiving
    /// any two final events. A transcript must stay within this fixed normalized CER threshold to
    /// count as the corresponding phrase; standard-mode results still report the unbounded CER.
    private static let reconnectMaximumCharacterErrorRate = 0.5

    private static func recognizedPhraseID(
        for transcript: String,
        among phrases: [Phrase]
    ) -> String? {
        let actual = normalize(transcript)
        guard !actual.isEmpty else { return nil }
        let matches = phrases.map { phrase -> (phrase: Phrase, errorRate: Double) in
            let expected = normalize(phrase.text)
            let distance = editDistance(expected, actual)
            let denominator = max(1, expected.count)
            return (phrase, Double(distance) / Double(denominator))
        }
        guard let closest = matches.min(by: { $0.errorRate < $1.errorRate }),
              closest.errorRate <= reconnectMaximumCharacterErrorRate else { return nil }
        return closest.phrase.id
    }

    private static func reconnectFinals(
        in events: [TranscriptionDiagnosticEvent],
        afterGeneration generation: Int
    ) -> [TranscriptionDiagnosticEvent] {
        events.filter { event in
            event.kind == .finalized
                && event.text?.isEmpty == false
                && event.generation > generation
        }.sorted {
            ($0.spokenAt ?? $0.observedAt) < ($1.spokenAt ?? $1.observedAt)
        }
    }

    private static func sequenceGapCount(_ observations: [CaptureObservation]) -> Int {
        zip(observations, observations.dropFirst()).count { previous, next in
            next.sequenceNumber != (previous.sequenceNumber &+ 1)
        }
    }
}
