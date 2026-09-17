import Foundation

/// Implementations must return immediately, must not throw, and must never invoke coaching
/// callbacks.
public protocol ActivityEventRecording: Sendable {
    func record(_ event: ActivityEvent, at date: Date)
}

public extension ActivityEventRecording {
    /// Speech passes its own speech time through `record(_:at:)` instead.
    func record(_ event: ActivityEvent) {
        record(event, at: Date())
    }
}
