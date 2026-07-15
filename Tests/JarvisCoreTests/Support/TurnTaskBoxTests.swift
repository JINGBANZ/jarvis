import Testing
import Foundation
@testable import JarvisCore

/// Thread-safe flag for observing a task's exit bookkeeping from the test.
private final class Flag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite struct TurnTaskBoxTests {
    /// `cancelAll` only *requests* cancellation; the returned tasks let a caller await the actual
    /// unwind. This is the contract AppDelegate's Stop relies on to keep Evaluate disabled until a
    /// cancelled turn's final traffic line has landed — pin it so a refactor can't drop the return.
    @Test func cancelAllReturnsTasksSoCallersCanAwaitTheUnwind() async {
        let box = TurnTaskBox()
        let exitBookkeepingDone = Flag()
        box.run {
            // Simulate a turn that notices cancellation, then still does exit bookkeeping
            // (like recording the cancelled round trip) before finishing.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
            exitBookkeepingDone.set()
        }
        let cancelled = box.cancelAll()
        #expect(cancelled.count == 1)
        for task in cancelled { await task.value }
        #expect(exitBookkeepingDone.isSet)   // draining waited for the bookkeeping, not just the cancel
    }

    @Test func cancelAllIsEmptyWhenNothingRan() {
        #expect(TurnTaskBox().cancelAll().isEmpty)
    }
}
