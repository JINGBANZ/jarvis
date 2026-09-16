import Foundation

/// The detail box's cursor over the session's details: which one is on screen, whether it is being
/// held there, and whether the box is rolled down to its title strip.
///
/// Foundation only, so the rule that decides whether a new reply takes the box is unit-tested
/// without a window. There is one detail box, so a later reply replaces a diagram unless the user
/// holds it: the arrows and Pin are that hold.
public struct DetailSlot: Equatable, Sendable {
    /// Into the session's ordered details. Nil until the first one arrives.
    public private(set) var shownIndex: Int?
    /// Pinned, or parked by stepping back. A held box ignores new details.
    public private(set) var isHeld: Bool
    /// Dismissed to the title strip, where the arrows and Pin stay reachable.
    public private(set) var isRolled: Bool

    public init(shownIndex: Int? = nil, isHeld: Bool = false, isRolled: Bool = false) {
        self.shownIndex = shownIndex
        self.isHeld = isHeld
        self.isRolled = isRolled
    }

    /// A reply delivered a detail. It fills the box unless the box is being held, in which case it
    /// waits in the session's list for the arrows to reach it.
    public mutating func received(_ index: Int) {
        guard !isHeld else { return }
        shownIndex = index
        isRolled = false
    }

    /// An arrow moved the box. It holds wherever it stops, and stepping forward onto the newest
    /// detail resumes following. Stepping also opens a rolled box: the user asked to see something.
    public mutating func step(to index: Int, isNewest: Bool) {
        shownIndex = index
        isHeld = !isNewest
        isRolled = false
    }

    /// Pin holds whatever is on screen in place.
    public mutating func pin() { isHeld = true }

    /// Unpin releases the box and jumps it to the newest detail, so following resumes from what the
    /// user would have seen.
    public mutating func unpin(newest: Int?) {
        isHeld = false
        if let newest { shownIndex = newest }
    }

    public mutating func roll(_ rolled: Bool) { isRolled = rolled }

    /// Stop, and Clear on a box that is not held.
    public mutating func reset() { self = DetailSlot() }
}
