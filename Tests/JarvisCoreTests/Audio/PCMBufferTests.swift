import Foundation
import Testing
@testable import JarvisCore

@Suite struct PCMBufferTests {
    @Test func appendsAndDrainsInOrder() {
        let b = PCMBuffer(maxBytes: 1000)
        b.append(Data([1, 2, 3]))
        b.append(Data([4, 5]))
        #expect(b.bufferedBytes == 5)
        let chunks = b.drain()
        #expect(chunks == [Data([1, 2, 3]), Data([4, 5])])
        #expect(b.bufferedBytes == 0)   // drain clears
    }

    /// Beyond the cap, the OLDEST audio is evicted (a long outage keeps only the most recent window).
    @Test func evictsOldestBeyondCap() {
        let b = PCMBuffer(maxBytes: 5)
        b.append(Data([1, 2, 3]))      // 3 bytes
        b.append(Data([4, 5, 6]))      // would be 6 > 5 → drop the first chunk
        #expect(b.bufferedBytes <= 5)
        #expect(b.drain() == [Data([4, 5, 6])])
    }

    /// The most recent chunk is always retained, even if it alone exceeds the cap.
    @Test func keepsNewestEvenIfLargerThanCap() {
        let b = PCMBuffer(maxBytes: 2)
        b.append(Data([1, 2, 3, 4]))
        #expect(b.drain() == [Data([1, 2, 3, 4])])
    }

    @Test func clearEmpties() {
        let b = PCMBuffer(maxBytes: 100)
        b.append(Data([9]))
        b.clear()
        #expect(b.bufferedBytes == 0)
        #expect(b.drain().isEmpty)
    }
}
