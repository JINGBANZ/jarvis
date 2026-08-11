import Testing
@testable import JarvisCore

@Suite struct ConversationChronologyTests {
    @Test func eventTimeOrdersItemsAndInsertionOrderBreaksTies() {
        var chronology = ConversationChronology<String>()
        chronology.append("later", occurredAt: 20)
        chronology.append("first tie", occurredAt: 10)
        chronology.append("second tie", occurredAt: 10)

        #expect(chronology.chronologicalItems.map(\.element) == [
            "first tie",
            "second tie",
            "later",
        ])
        #expect(chronology.chronologicalIndex(forInsertionOrder: 0) == 2)
        #expect(chronology.chronologicalIndex(forInsertionOrder: 1) == 0)
    }

    @Test func appendCursorStaysStableWhileItsViewIsChronological() {
        var chronology = ConversationChronology<String>()
        chronology.append("committed", occurredAt: 1)
        chronology.append("reply", occurredAt: 20)
        chronology.append("question", occurredAt: 10)

        let delta = chronology.snapshot(fromInsertionIndex: 1)
        #expect(delta.insertionOrderedItems.map(\.element) == ["reply", "question"])
        #expect(delta.chronologicalItems.map(\.element) == ["question", "reply"])
        #expect(delta.upToInsertionIndex == 3)
    }
}
