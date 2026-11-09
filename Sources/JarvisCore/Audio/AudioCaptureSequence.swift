/// Identifies captured chunks and reserves a missing identifier at a capture continuity break.
public struct AudioCaptureSequence: Sendable {
    private var value: UInt64 = 0

    public init() {}

    public mutating func next() -> UInt64 {
        value &+= 1
        return value
    }

    public mutating func markDiscontinuity() {
        value &+= 1
    }
}
