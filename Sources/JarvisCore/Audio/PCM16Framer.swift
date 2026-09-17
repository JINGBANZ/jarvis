import Foundation

/// AEC3 accepts only exact 10 ms frames (480 samples at 48 kHz), but capture delivers any size.
public struct PCM16Framer {
    public let frameSize: Int
    private var pending: [Int16] = []

    public init(frameSize: Int) {
        self.frameSize = max(1, frameSize)
    }

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
