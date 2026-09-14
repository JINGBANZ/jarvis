import Foundation
import Testing
@testable import JarvisCore

@Suite struct ScreenObservationMemoryTests {
    private func browser(_ text: String, truncated: Bool = false) -> ScreenTextEvidence {
        ScreenTextEvidence(
            text: text,
            source: .browserAccessibility,
            coverage: .activeTabAccessibilityTree,
            truncated: truncated)
    }

    @Test func keepsSeparateObservationsAndRefreshesOnlyExactKnownSourceDuplicates() {
        var memory = ScreenObservationMemory()
        memory.record(evidence: browser("count = 1"), sourceID: "window:1", elapsedSeconds: 1)
        memory.record(evidence: browser("count = 0"), sourceID: "window:1", elapsedSeconds: 2)
        memory.record(evidence: browser("count = 1"), sourceID: "window:2", elapsedSeconds: 3)
        memory.record(evidence: browser("count = 0"), sourceID: "window:1", elapsedSeconds: 4)
        #expect(memory.observations.map(\.id) == [1, 3, 4])
        #expect(memory.observations.map(\.text) == ["count = 1", "count = 1", "count = 0"])
        memory.record(evidence: browser("unknown document"), sourceID: nil, elapsedSeconds: 5)
        memory.record(evidence: browser("unknown document"), sourceID: nil, elapsedSeconds: 6)
        #expect(memory.observations.count == 5)
    }

    @Test func byteAndCountBoundsDiscloseMissingContextWithoutCorruptingUnicode() {
        var memory = ScreenObservationMemory(byteLimit: 10, observationLimit: 2)
        memory.record(evidence: browser("old"), sourceID: nil, elapsedSeconds: 1)
        memory.record(evidence: browser("new"), sourceID: nil, elapsedSeconds: 2)
        memory.record(evidence: browser("last"), sourceID: nil, elapsedSeconds: 3)
        #expect(memory.observations.map(\.text) == ["new", "last"])
        #expect(memory.hasOmissions)
        memory.record(evidence: browser("中文中文"), sourceID: nil, elapsedSeconds: 4)
        #expect(memory.observations.map(\.text) == ["中文中"])
        #expect(memory.observations[0].truncated)
        #expect(memory.observations.reduce(0) { $0 + $1.text.utf8.count } <= 10)
    }

    @Test func resetKeepsOnlyThisAttemptAndNeverReusesObservationIDs() {
        var memory = ScreenObservationMemory()
        memory.record(evidence: browser("old question"), sourceID: nil, elapsedSeconds: 1)
        let boundary = memory.latestID
        memory.record(evidence: browser("new question"), sourceID: nil, elapsedSeconds: 2)
        memory.apply(.init(newQuestion: true, obsoleteObservationIDs: []), after: boundary, visibleIDs: [1, 2])
        #expect(memory.observations.map(\.text) == ["new question"])
        memory.record(evidence: browser("new code"), sourceID: nil, elapsedSeconds: 3)
        #expect(memory.observations.map(\.id) == [2, 3])
        memory.apply(.init(newQuestion: false, obsoleteObservationIDs: [2, 3, 99]), after: 3, visibleIDs: [2])
        #expect(memory.observations.map(\.id) == [3])
        #expect(ScreenObservationMemory().observations.isEmpty)
    }

    @Test func resetDisclosesEvictedCurrentEvidenceButClearsOldQuestionOmissions() {
        var memory = ScreenObservationMemory(byteLimit: 10)
        memory.record(evidence: browser("firstpart"), sourceID: nil, elapsedSeconds: 1)
        memory.record(evidence: browser("secondpart"), sourceID: nil, elapsedSeconds: 2)
        memory.apply(.init(newQuestion: true, obsoleteObservationIDs: []), after: 0, visibleIDs: [1, 2])
        #expect(memory.observations.map(\.text) == ["secondpart"])
        #expect(memory.hasOmissions)
        // A carried retry observation can have been evicted after the retry starts.
        memory.apply(.init(newQuestion: true, obsoleteObservationIDs: []), after: 2,
                     visibleIDs: [1, 2], keepingIDs: [1, 2])
        #expect(memory.hasOmissions)
        memory.record(evidence: browser("third"), sourceID: nil, elapsedSeconds: 3)
        memory.apply(.init(newQuestion: true, obsoleteObservationIDs: []), after: 2, visibleIDs: [3])
        #expect(memory.observations.map(\.text) == ["third"])
        #expect(!memory.hasOmissions)
    }

    @Test func emptyOCRDoesNotClearEvidenceAndLossSurvivesEmptyContext() {
        var memory = ScreenObservationMemory(byteLimit: 0)
        memory.record(evidence: browser(""), sourceID: nil, elapsedSeconds: 1)
        #expect(memory.contextMessage() == nil)
        memory.record(evidence: browser("not retained"), sourceID: nil, elapsedSeconds: 2)
        #expect(memory.hasOmissions)
        #expect(memory.contextMessage() != nil)
    }

    @Test func fallbackOCRNeverEntersHistoricalMemory() {
        var memory = ScreenObservationMemory()
        let id = memory.record(
            evidence: ScreenTextEvidence(
                text: "return _1", source: .onDeviceOCR, coverage: .currentViewport),
            sourceID: "window:1",
            elapsedSeconds: 1)

        #expect(id == nil)
        #expect(memory.contextMessage() == nil)
    }

    @Test func historicalContextCarriesSourceCoverageAndTruncation() throws {
        var memory = ScreenObservationMemory()
        memory.record(evidence: browser("partial", truncated: true),
                      sourceID: "window:1", elapsedSeconds: 1)

        let message = try #require(memory.contextMessage())
        #expect(message.text?.contains(#""source":"browserAccessibility""#) == true)
        #expect(message.text?.contains(#""coverage":"activeTabAccessibilityTree""#) == true)
        #expect(message.text?.contains(#""truncated":true"#) == true)
    }

    @Test func malformedMaintenanceCannotClearMemory() {
        #expect(ScreenMemoryUpdate.parse(#"{"screenMemory":{"newQuestion":"false","obsoleteObservationIDs":[]}}"#) == nil)
        #expect(ScreenMemoryUpdate.parse(#"{"screenMemory":{"newQuestion":true,"obsoleteObservationIDs":[-1]}}"#) == nil)
        #expect(ScreenMemoryUpdate.parse(#"{"screenMemory":{"newQuestion":true,"obsoleteObservationIDs":[true]}}"#) == nil)
        #expect(ScreenMemoryUpdate.parse(#"{"screenMemory":null}"#) == nil)
        #expect(ScreenMemoryUpdate.parse(#"{"screenMemory":{"newQuestion":true,"obsoleteObservationIDs":[1,2]}}"#)
                == .init(newQuestion: true, obsoleteObservationIDs: [1, 2]))
    }
}
