import Foundation

/// One ordering policy for conversation-derived data.
///
/// Event time is authoritative. Insertion order is only a stable tie-breaker for events with the
/// same timestamp. The stored array remains in insertion order so append-index cursors stay valid;
/// consumers ask this component for chronological views instead of sorting that backing array.
public struct ConversationChronology<Element: Sendable>: Sendable {
    public struct Item: Sendable {
        public let element: Element
        public let occurredAt: TimeInterval
        public let insertionOrder: UInt64
    }

    public struct Snapshot: Sendable {
        public let insertionOrderedItems: [Item]
        public let chronologicalItems: [Item]
        public let upToInsertionIndex: Int
    }

    private var items: [Item] = []
    private var nextInsertionOrder: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func append(_ element: Element, occurredAt: TimeInterval) -> Item {
        precondition(occurredAt.isFinite, "Conversation event time must be finite")
        let item = Item(
            element: element,
            occurredAt: occurredAt,
            insertionOrder: nextInsertionOrder)
        nextInsertionOrder &+= 1
        items.append(item)
        return item
    }

    public var count: Int { items.count }

    public var latestOccurredAt: TimeInterval? {
        items.map(\.occurredAt).max()
    }

    public var chronologicalItems: [Item] {
        Self.order(items)
    }

    /// Locate one appended item in the authoritative chronological view. Activity uses this to tell
    /// its thin WebView exactly where to insert a live row; JavaScript does not reimplement policy.
    public func chronologicalIndex(forInsertionOrder insertionOrder: UInt64) -> Int? {
        chronologicalItems.firstIndex { $0.insertionOrder == insertionOrder }
    }

    /// Return one append-index delta in both representations. The insertion view preserves stable
    /// provenance indices; the chronological view is the order shown to humans and the model.
    public func snapshot(fromInsertionIndex index: Int) -> Snapshot {
        let start = min(max(0, index), items.count)
        let insertionOrdered = Array(items[start...])
        return Snapshot(
            insertionOrderedItems: insertionOrdered,
            chronologicalItems: Self.order(insertionOrdered),
            upToInsertionIndex: items.count)
    }

    public mutating func removeAll() {
        items.removeAll(keepingCapacity: false)
        nextInsertionOrder = 0
    }

    /// Activity uses this only as a runaway memory backstop. Ordering keys remain monotonic even
    /// when old insertion records are discarded.
    @discardableResult
    public mutating func keepMostRecentInsertions(_ maximumCount: Int) -> [Item] {
        let maximumCount = max(0, maximumCount)
        guard items.count > maximumCount else { return [] }
        let removalCount = items.count - maximumCount
        let removed = Array(items.prefix(removalCount))
        items.removeFirst(removalCount)
        return removed
    }

    /// Order an arbitrary sequence with the same event-time/insertion-time rule. The sequence's
    /// current order supplies the stable tie-breaker.
    public static func ordered<S: Sequence>(
        _ elements: S,
        occurredAt: (Element) -> TimeInterval
    ) -> [Element] where S.Element == Element {
        elements.enumerated()
            .map { offset, element -> Item in
                let time = occurredAt(element)
                precondition(time.isFinite, "Conversation event time must be finite")
                return Item(
                    element: element,
                    occurredAt: time,
                    insertionOrder: UInt64(offset))
            }
            .sorted(by: precedes)
            .map(\.element)
    }

    private static func order(_ items: [Item]) -> [Item] {
        items.sorted(by: precedes)
    }

    private static func precedes(_ lhs: Item, _ rhs: Item) -> Bool {
        if lhs.occurredAt != rhs.occurredAt {
            return lhs.occurredAt < rhs.occurredAt
        }
        return lhs.insertionOrder < rhs.insertionOrder
    }
}
