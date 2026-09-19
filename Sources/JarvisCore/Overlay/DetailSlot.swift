import Foundation

public struct DetailSlot: Equatable, Sendable {
    /// Nil until the first detail arrives.
    public private(set) var shownIndex: Int?
    /// Pinned, or parked by stepping back.
    public private(set) var isHeld: Bool
    /// Dismissed to the title strip.
    public private(set) var isRolled: Bool

    public init(shownIndex: Int? = nil, isHeld: Bool = false, isRolled: Bool = false) {
        self.shownIndex = shownIndex
        self.isHeld = isHeld
        self.isRolled = isRolled
    }

    public mutating func received(_ index: Int) {
        guard !isHeld else { return }
        shownIndex = index
        isRolled = false
    }

    public mutating func step(to index: Int, isNewest: Bool) {
        shownIndex = index
        isHeld = !isNewest
        isRolled = false
    }

    /// The detail at `index` left the list, so the ones after it moved down; a box showing it moves
    /// to the one before, keeping its hold.
    public mutating func removed(_ index: Int) {
        guard let shown = shownIndex, shown >= index else { return }
        shownIndex = shown == 0 ? nil : shown - 1
    }

    public mutating func pin() { isHeld = true }

    public mutating func unpin(newest: Int?) {
        isHeld = false
        if let newest { shownIndex = newest }
    }

    public mutating func roll(_ rolled: Bool) { isRolled = rolled }

    public mutating func reset() { self = DetailSlot() }
}
