import Testing
import Foundation
@testable import JarvisCore

/// @unchecked: lock guards value.
private final class Flag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite struct TurnTaskBoxTests {
    @Test func cancelAllReturnsTasksSoCallersCanAwaitTheUnwind() async {
        let box = TurnTaskBox()
        let exitBookkeepingDone = Flag()
        box.run {
            // Exit bookkeeping still runs after the task notices cancellation.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
            exitBookkeepingDone.set()
        }
        let cancelled = box.cancelAll()
        #expect(cancelled.count == 1)
        for task in cancelled { await task.value }
        #expect(exitBookkeepingDone.isSet)
    }

    @Test func cancelAllIsEmptyWhenNothingRan() {
        #expect(TurnTaskBox().cancelAll().isEmpty)
    }
}
