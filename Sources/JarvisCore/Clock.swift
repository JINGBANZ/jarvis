import Foundation

/// Monotonic-ish seconds source, injectable so logic is testable without real time.
public protocol Clock: AnyObject {
    func now() -> TimeInterval
}

public final class SystemClock: Clock {
    public init() {}
    public func now() -> TimeInterval { Date().timeIntervalSince1970 }
}

/// Test clock with manual control.
public final class ManualClock: Clock {
    private var current: TimeInterval
    public init(now: TimeInterval = 0) { self.current = now }
    public func now() -> TimeInterval { current }
    public func advance(by delta: TimeInterval) { current += delta }
    public func set(_ value: TimeInterval) { current = value }
}
