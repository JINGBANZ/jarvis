import Testing
@testable import JarvisCore

@Suite struct DetailSlotTests {
    @Test func anUnheldBoxFollowsTheNewestDetail() {
        var slot = DetailSlot()
        slot.received(0)
        #expect(slot.shownIndex == 0)
        slot.received(1)
        #expect(slot.shownIndex == 1)
        #expect(!slot.isHeld)
    }

    @Test func steppingBackHoldsTheBoxAndLaterDetailsWait() {
        var slot = DetailSlot()
        slot.received(0)
        slot.received(1)
        slot.step(to: 0, isNewest: false)
        #expect(slot.shownIndex == 0)
        #expect(slot.isHeld)

        slot.received(2)
        #expect(slot.shownIndex == 0)
    }

    @Test func steppingForwardOntoTheNewestResumesFollowing() {
        var slot = DetailSlot()
        slot.received(0)
        slot.received(1)
        slot.step(to: 0, isNewest: false)
        slot.step(to: 1, isNewest: true)
        #expect(!slot.isHeld)
        slot.received(2)
        #expect(slot.shownIndex == 2)
    }

    @Test func pinHoldsTheNewestAndUnpinJumpsBackToIt() {
        var slot = DetailSlot()
        slot.received(0)
        slot.pin()
        slot.received(1)
        #expect(slot.shownIndex == 0)

        slot.unpin(newest: 1)
        #expect(!slot.isHeld)
        #expect(slot.shownIndex == 1)
    }

    @Test func aNewDetailOpensARolledBoxAndSteppingDoesToo() {
        var slot = DetailSlot()
        slot.received(0)
        slot.roll(true)
        #expect(slot.isRolled)
        slot.received(1)
        #expect(!slot.isRolled)

        slot.roll(true)
        slot.step(to: 0, isNewest: false)
        #expect(!slot.isRolled)
    }

    /// A held box stays rolled: the user dismissed it and asked for it to stay put.
    @Test func aHeldRolledBoxStaysRolled() {
        var slot = DetailSlot()
        slot.received(0)
        slot.pin()
        slot.roll(true)
        slot.received(1)
        #expect(slot.isRolled)
        #expect(slot.shownIndex == 0)
    }

    @Test func resetClearsEverything() {
        var slot = DetailSlot()
        slot.received(3)
        slot.pin()
        slot.roll(true)
        slot.reset()
        #expect(slot == DetailSlot())
        #expect(slot.shownIndex == nil)
        #expect(!slot.isHeld)
        #expect(!slot.isRolled)
    }
}
