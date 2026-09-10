import Foundation
import Testing
@testable import JarvisCore

@Suite struct ScreenObservationMemoryTests {
    @Test func keepsSeparateObservationsAndRefreshesOnlyExactKnownSourceDuplicates() {
        var memory = ScreenObservationMemory()
        memory.record(text: "count = 1", sourceID: "window:1", elapsedSeconds: 1)
        memory.record(text: "count = 0", sourceID: "window:1", elapsedSeconds: 2)
        memory.record(text: "count = 1", sourceID: "window:2", elapsedSeconds: 3)
        memory.record(text: "count = 0", sourceID: "window:1", elapsedSeconds: 4)
        #expect(memory.observations.map(\.id) == [1, 3, 4])
        #expect(memory.observations.map(\.text) == ["count = 1", "count = 1", "count = 0"])
        memory.record(text: "unknown document", sourceID: nil, elapsedSeconds: 5)
        memory.record(text: "unknown document", sourceID: nil, elapsedSeconds: 6)
        #expect(memory.observations.count == 5)
    }

    @Test func byteAndCountBoundsDiscloseMissingContextWithoutCorruptingUnicode() {
        var memory = ScreenObservationMemory(byteLimit: 10, observationLimit: 2)
        memory.record(text: "old", sourceID: nil, elapsedSeconds: 1)
        memory.record(text: "new", sourceID: nil, elapsedSeconds: 2)
        memory.record(text: "last", sourceID: nil, elapsedSeconds: 3)
        #expect(memory.observations.map(\.text) == ["new", "last"])
        #expect(memory.hasOmissions)
        memory.record(text: "中文中文", sourceID: nil, elapsedSeconds: 4)
        #expect(memory.observations.map(\.text) == ["中文中"])
        #expect(memory.observations[0].truncated)
        #expect(memory.observations.reduce(0) { $0 + $1.text.utf8.count } <= 10)
    }

    @Test func resetKeepsOnlyThisAttemptAndNeverReusesObservationIDs() {
        var memory = ScreenObservationMemory()
        memory.record(text: "old question", sourceID: nil, elapsedSeconds: 1)
        let boundary = memory.latestID
        memory.record(text: "new question", sourceID: nil, elapsedSeconds: 2)
        memory.apply(.init(newQuestion: true, obsoleteObservationIDs: []), after: boundary, visibleIDs: [1, 2])
        #expect(memory.observations.map(\.text) == ["new question"])
        memory.record(text: "new code", sourceID: nil, elapsedSeconds: 3)
        #expect(memory.observations.map(\.id) == [2, 3])
        memory.apply(.init(newQuestion: false, obsoleteObservationIDs: [2, 3, 99]), after: 3, visibleIDs: [2])
        #expect(memory.observations.map(\.id) == [3])
        #expect(ScreenObservationMemory().observations.isEmpty)
    }

    @Test func emptyOCRDoesNotClearEvidenceAndLossSurvivesEmptyContext() {
        var memory = ScreenObservationMemory(byteLimit: 0)
        memory.record(text: "", sourceID: nil, elapsedSeconds: 1)
        #expect(memory.contextMessage() == nil)
        memory.record(text: "not retained", sourceID: nil, elapsedSeconds: 2)
        #expect(memory.hasOmissions)
        #expect(memory.contextMessage() != nil)
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
