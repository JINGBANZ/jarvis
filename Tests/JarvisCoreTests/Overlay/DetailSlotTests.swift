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

    @Test func steppingBackLeavesTheBoxUnpinnedAndLaterDetailsReplaceIt() {
        var slot = DetailSlot()
        slot.received(0)
        slot.received(1)
        slot.step(to: 0)
        #expect(slot.shownIndex == 0)
        #expect(!slot.isHeld)

        slot.received(2)
        #expect(slot.shownIndex == 2)
    }

    @Test func navigationPreservesAnExplicitPin() {
        var slot = DetailSlot()
        slot.received(0)
        slot.received(1)
        slot.pin()
        slot.step(to: 0)
        #expect(slot.isHeld)
        slot.received(2)
        #expect(slot.shownIndex == 0)

        slot.step(to: 2)
        #expect(slot.isHeld)
        slot.received(3)
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
        slot.step(to: 0)
        #expect(!slot.isRolled)
    }

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
