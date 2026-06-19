import Foundation

/// Re-chunks a stream of PCM16 samples into fixed-size frames. The echo canceller (AEC3) only
/// accepts exact 10 ms frames (480 samples at 48 kHz), but the capture sources hand us
/// arbitrary chunk sizes — so we accumulate samples and emit complete frames as they fill, holding
/// the leftover for the next push. Pure value type so the framing is unit-tested without any audio
/// hardware (the AEC wiring that uses it lives at the OS-bound edge).
public struct PCM16Framer {
    public let frameSize: Int
    private var pending: [Int16] = []

    public init(frameSize: Int) {
        self.frameSize = max(1, frameSize)
    }

    /// Append `samples`, then return every complete `frameSize` frame now available, retaining any
    /// remainder for a later push.
    public mutating func push(_ samples: [Int16]) -> [[Int16]] {
        pending.append(contentsOf: samples)
        guard pending.count >= frameSize else { return [] }
        var frames: [[Int16]] = []
        var offset = 0
        while pending.count - offset >= frameSize {
            frames.append(Array(pending[offset ..< offset + frameSize]))
            offset += frameSize
        }
        pending.removeFirst(offset)
        return frames
    }
}
