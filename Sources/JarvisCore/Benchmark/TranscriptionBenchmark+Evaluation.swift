import Foundation

public extension TranscriptionBenchmark {
    static func standardAcceptanceFailureArmIDs(
        in summary: Summary,
        expectedRepetitions: Int,
        requiredProviders: Set<TranscriptionProvider>
    ) -> [String] {
        summary.arms.compactMap { arm -> String? in
            if arm.unavailableReason != nil {
                return requiredProviders.contains(arm.arm.provider) ? arm.arm.id : nil
            }
            guard arm.repetitions.count == expectedRepetitions,
                  arm.repetitions.allSatisfy({ $0.failure == nil && $0.continuityPassed }) else {
                return arm.arm.id
            }
            return nil
        }.sorted()
    }

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
            !event.transcriptUnavailable
                && event.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let finalTexts = usableFinals.compactMap(\.text)
        let finalItemIDs = usableFinals.compactMap(\.itemID)
        let expected = normalize(input.arm.phrase.text)
        let actual = normalize(finalTexts.joined(separator: " "))
        let distance = actual.isEmpty ? nil : editDistance(expected, actual)
        let rate = distance.map { expected.isEmpty ? 0 : Double($0) / Double(expected.count) }

        let providerUsableFinals = providerFinals.filter {
            !$0.transcriptUnavailable
                && $0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let rawFinalsForRevision = providerFinals.isEmpty ? usableFinals : providerUsableFinals
        let rawFinalTexts = rawFinalsForRevision.compactMap(\.text).map(normalize)
        var textsByItem: [String: Set<String>] = [:]
        for final in rawFinalsForRevision {
            guard let itemID = final.itemID, let text = final.text else { continue }
            textsByItem[itemID, default: []].insert(normalize(text))
        }
        let revisionCount = textsByItem.values.reduce(0) { $0 + max(0, $1.count - 1) }
        // A provider may legitimately split one fixture across distinct finalized items. Count only
        // repeated item identities or repeated normalized text, not every fragment after the first.
        let duplicateCount = duplicateDeliveryCount(in: usableFinals)
        let providerDuplicateCount = max(
            0,
            rawFinalTexts.count - Set(rawFinalTexts).count)
        let captureSequenceGapCount = sequenceGapCount(input.captureObservations)
        let capturedSampleCount = input.captureObservations.reduce(0) { $0 + $1.sampleCount }
        let evictedChunkCount = bufferEvictions.compactMap(\.evictedChunks).reduce(0, +)
        let unavailableEvents = orderedEvents.filter {
            ($0.kind == .providerFinal || $0.kind == .finalized)
                && $0.transcriptUnavailable
        }
        let unavailableItemIDs = Set(unavailableEvents.compactMap(\.itemID))
        let unavailableWithoutItemID = unavailableEvents.count(where: { $0.itemID == nil })
        let reconnected = input.connectionStates.contains { state in
            if case .reconnecting = state { return true }
            return false
        }
        let failure = input.failure ?? (reconnected
            ? "Transcription reconnected during a standard benchmark repetition"
            : nil)

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
            finalLatencySeconds: usableFinals.last.map {
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
            failure: failure)
    }

    static func evaluateReconnect(
        model: OpenAITranscriptionModel,
        phraseIDs: [String],
        events: [TranscriptionBenchmarkEvent],
        captureObservations: [CaptureObservation] = [],
        failure: String? = nil
    ) -> ReconnectSummary {
        let readyEvents = events.filter { $0.kind == .ready }.sorted {
            $0.observedAt < $1.observedAt
        }
        let initialGeneration = readyEvents.first?.generation
        let replacementGeneration = initialGeneration.flatMap { initialGeneration in
            readyEvents.first { $0.generation > initialGeneration }?.generation
        }
        let replacementFinalCount = replacementGeneration.map { generation in
            events.count {
                $0.kind == .finalized && $0.generation == generation
            }
        } ?? 0
        let finals = replacementGeneration.map {
            reconnectFinals(in: events, generation: $0)
        } ?? []
        let finalTexts = finals.compactMap(\.text)
        let recognition = reconnectPhraseRecognition(phraseIDs, in: finals)
        let finalPhraseIDs = recognition.phraseIDs
        let exactlyOnce = replacementFinalCount == finals.count
            && recognition.consumesEveryFinal
            && duplicateDeliveryCount(in: finals) == 0
            && phraseIDs.allSatisfy { expected in
            finalPhraseIDs.count(where: { $0 == expected }) == 1
        } && finalPhraseIDs.count == phraseIDs.count
        let ordered = finalPhraseIDs == phraseIDs
        let noFallback = !readyEvents.isEmpty && readyEvents.allSatisfy {
            $0.provider == TranscriptionProvider.openAI.rawValue
                && $0.model == model.rawValue
        }
        let readyGenerations = Array(Set(readyEvents.map(\.generation))).sorted()
        // The successful replacement-ready event reports the FIFO actually replayed into the
        // generation whose finals are scored. Earlier or later reconnect hops cannot lend evidence
        // to this one acceptance result.
        let replayEvents = replacementGeneration.map { replacementGeneration in
            events.filter {
                $0.kind == .ready && $0.generation == replacementGeneration
            }
        } ?? []
        let reconnectPreparedEvents = initialGeneration.map { initialGeneration in
            events.filter {
                $0.kind == .reconnectPrepared && $0.generation == initialGeneration
            }
        } ?? []
        let replacementDropped = replacementGeneration.map { replacementGeneration in
            events.contains {
                $0.kind == .reconnectPrepared && $0.generation >= replacementGeneration
            }
        } ?? false
        let replayedChunks = replayEvents.compactMap(\.replayedChunks).max() ?? 0
        let bufferEvictionEvents = events.filter { event in
            guard let initialGeneration, let replacementGeneration else { return false }
            return event.kind == .bufferEviction
                && event.generation >= initialGeneration
                && event.generation <= replacementGeneration
        }
        let evictedChunks = bufferEvictionEvents.isEmpty
            ? reconnectPreparedEvents.compactMap(\.evictedChunks).reduce(0, +)
            : bufferEvictionEvents.compactMap(\.evictedChunks).reduce(0, +)
        let captureSequenceGapCount = sequenceGapCount(captureObservations)
        let capturedSampleCount = captureObservations.reduce(0) { $0 + $1.sampleCount }
        let continuityPassed = !captureObservations.isEmpty
            && capturedSampleCount > 0
            && captureSequenceGapCount == 0
            && replayedChunks > 0
            && evictedChunks == 0
        let passed = failure == nil
            && readyGenerations.count == 2
            && exactlyOnce
            && ordered
            && noFallback
            && continuityPassed
            && !replacementDropped
        let reportedFailure: String?
        if let failure {
            reportedFailure = failure
        } else if replacementDropped {
            reportedFailure = "Replacement connection dropped before the reconnect snapshot"
        } else {
            reportedFailure = passed ? nil : "Reconnect acceptance criteria were not met"
        }
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
            failure: reportedFailure)
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
        in events: [TranscriptionBenchmarkEvent],
        generation: Int
    ) -> [String] {
        let expectedPhrases = phraseIDs.compactMap { id in
            phrases.first { $0.id == id }
        }
        let finals = reconnectFinals(in: events, generation: generation)
        if let partition = bestReconnectPartition(
            finals,
            groupCount: phraseIDs.count,
            expectedPhrases: expectedPhrases)
        {
            return partition.phraseIDs
        }
        return finals.compactMap { event in
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
        recognizedPhraseMatch(for: transcript, among: phrases)?.phraseID
    }

    private static func recognizedPhraseMatch(
        for transcript: String,
        among phrases: [Phrase]
    ) -> ReconnectPhraseMatch? {
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
        return ReconnectPhraseMatch(
            phraseID: closest.phrase.id,
            errorRate: closest.errorRate)
    }

    private static func reconnectPhraseRecognition(
        _ phraseIDs: [String],
        in finals: [TranscriptionBenchmarkEvent]
    ) -> ReconnectPhraseRecognition {
        let expectedPhrases = phraseIDs.compactMap { id in
            phrases.first { $0.id == id }
        }
        if let partition = bestReconnectPartition(
            finals,
            groupCount: phraseIDs.count,
            expectedPhrases: expectedPhrases)
        {
            return ReconnectPhraseRecognition(
                phraseIDs: partition.phraseIDs,
                consumesEveryFinal: true)
        }
        let independentlyRecognized: [String] = finals.compactMap { event in
            guard let text = event.text else { return nil }
            return recognizedPhraseID(for: text, among: expectedPhrases)
        }
        return ReconnectPhraseRecognition(
            phraseIDs: independentlyRecognized,
            consumesEveryFinal: false)
    }

    /// Finds the lowest-error partition that reconstructs the expected number of phrases from all
    /// usable replacement-generation finals. Every item in a multi-event group must improve the
    /// reconstruction: the group must beat each fragment alone and removing any member must make
    /// the match worse. This permits real segmentation without absorbing an unrelated extra final.
    private static func bestReconnectPartition(
        _ finals: [TranscriptionBenchmarkEvent],
        groupCount: Int,
        expectedPhrases: [Phrase]
    ) -> ReconnectPartition? {
        guard groupCount > 0,
              expectedPhrases.count == groupCount,
              finals.count >= groupCount else { return nil }
        var best: ReconnectPartition?

        func search(
            finalIndex: Int,
            groupIndex: Int,
            phraseIDs: [String],
            totalErrorRate: Double
        ) {
            if groupIndex == groupCount {
                guard finalIndex == finals.count else { return }
                let candidate = ReconnectPartition(
                    phraseIDs: phraseIDs,
                    totalErrorRate: totalErrorRate)
                if best.map({ candidate.totalErrorRate < $0.totalErrorRate }) ?? true {
                    best = candidate
                }
                return
            }

            let remainingGroups = groupCount - groupIndex
            let maximumEnd = finals.count - (remainingGroups - 1)
            guard finalIndex < maximumEnd else { return }
            for end in (finalIndex + 1)...maximumEnd {
                let group = finals[finalIndex..<end]
                let text = group.compactMap(\.text).joined(separator: " ")
                guard let match = recognizedPhraseMatch(
                    for: text,
                    among: expectedPhrases)
                else { continue }
                if group.count > 1,
                   !groupImprovesRecognition(
                       group,
                       combinedMatch: match,
                       expectedPhrases: expectedPhrases)
                {
                    continue
                }
                search(
                    finalIndex: end,
                    groupIndex: groupIndex + 1,
                    phraseIDs: phraseIDs + [match.phraseID],
                    totalErrorRate: totalErrorRate + match.errorRate)
            }
        }

        search(finalIndex: 0, groupIndex: 0, phraseIDs: [], totalErrorRate: 0)
        return best
    }

    private static func groupImprovesRecognition(
        _ group: ArraySlice<TranscriptionBenchmarkEvent>,
        combinedMatch: ReconnectPhraseMatch,
        expectedPhrases: [Phrase]
    ) -> Bool {
        guard let phrase = expectedPhrases.first(where: {
            $0.id == combinedMatch.phraseID
        }) else { return false }
        let expected = normalize(phrase.text)
        let denominator = max(1, expected.count)
        let texts = group.compactMap(\.text)
        guard texts.count == group.count,
              texts.allSatisfy({ text in
                  let fragmentErrorRate = Double(editDistance(expected, normalize(text)))
                      / Double(denominator)
                  return combinedMatch.errorRate < fragmentErrorRate
              })
        else { return false }
        return texts.indices.allSatisfy { excludedIndex in
            let withoutText = texts.enumerated()
                .filter { $0.offset != excludedIndex }
                .map(\.element)
                .joined(separator: " ")
            let withoutErrorRate = Double(editDistance(expected, normalize(withoutText)))
                / Double(denominator)
            return combinedMatch.errorRate < withoutErrorRate
        }
    }

    private static func reconnectFinals(
        in events: [TranscriptionBenchmarkEvent],
        generation: Int
    ) -> [TranscriptionBenchmarkEvent] {
        events.enumerated().filter { _, event in
            event.kind == .finalized
                && !event.transcriptUnavailable
                && event.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && event.generation == generation
        }.sorted {
            let lhsTime = $0.element.spokenAt ?? $0.element.observedAt
            let rhsTime = $1.element.spokenAt ?? $1.element.observedAt
            if lhsTime != rhsTime { return lhsTime < rhsTime }
            if $0.element.observedAt != $1.element.observedAt {
                return $0.element.observedAt < $1.element.observedAt
            }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    private struct ReconnectPhraseMatch {
        let phraseID: String
        let errorRate: Double
    }

    private struct ReconnectPhraseRecognition {
        let phraseIDs: [String]
        let consumesEveryFinal: Bool
    }

    private struct ReconnectPartition {
        let phraseIDs: [String]
        let totalErrorRate: Double
    }

    private static func duplicateDeliveryCount(
        in events: [TranscriptionBenchmarkEvent]
    ) -> Int {
        var seenItemIDs: Set<String> = []
        var seenTexts: Set<String> = []
        return events.count { event in
            let repeatedItem = event.itemID.map { !seenItemIDs.insert($0).inserted } ?? false
            let text = event.text.map(normalize) ?? ""
            let repeatedText = !text.isEmpty && !seenTexts.insert(text).inserted
            return repeatedItem || repeatedText
        }
    }

    private static func sequenceGapCount(_ observations: [CaptureObservation]) -> Int {
        zip(observations, observations.dropFirst()).count { previous, next in
            next.sequenceNumber != (previous.sequenceNumber &+ 1)
        }
    }
}
