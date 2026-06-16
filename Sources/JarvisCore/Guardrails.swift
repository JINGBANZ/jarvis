import Foundation

/// Behavioral safety: cooldown between utterances, a rolling per-minute rate cap, and mute.
/// All time comes from an injected Clock so this is fully testable.
public final class Guardrails: @unchecked Sendable {
    private let cooldownSeconds: TimeInterval
    private let maxInterjectionsPerMinute: Int
    private let maxDirectAddressesPerMinute: Int
    private let clock: Clock
    private let lock = NSLock()

    private var lastSpokeAt: TimeInterval?
    private var spokeTimestamps: [TimeInterval] = []
    private var directTimestamps: [TimeInterval] = []
    private var muted = false

    public init(cooldownSeconds: TimeInterval, maxInterjectionsPerMinute: Int,
                maxDirectAddressesPerMinute: Int = 8, clock: Clock) {
        self.cooldownSeconds = cooldownSeconds
        self.maxInterjectionsPerMinute = maxInterjectionsPerMinute
        self.maxDirectAddressesPerMinute = maxDirectAddressesPerMinute
        self.clock = clock
    }

    public func setMuted(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        muted = value
    }

    public var isMuted: Bool {
        lock.lock(); defer { lock.unlock() }
        return muted
    }

    /// True if a spoken response is permitted right now.
    public func allow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if muted { return false }
        let now = clock.now()
        if let last = lastSpokeAt, now - last < cooldownSeconds { return false }
        let recent = spokeTimestamps.filter { now - $0 < 60 }
        if recent.count >= maxInterjectionsPerMinute { return false }
        return true
    }

    /// Record that a response was spoken; starts the cooldown and counts toward the rate cap.
    public func noteSpoke() {
        lock.lock(); defer { lock.unlock() }
        let now = clock.now()
        lastSpokeAt = now
        spokeTimestamps.append(now)
        spokeTimestamps = spokeTimestamps.filter { now - $0 < 60 }
    }

    /// True if a direct-address reply is permitted now: ignores the cooldown/ambient rate cap, but
    /// honors mute and a separate, looser per-minute ceiling so a false wake-match can't spam.
    public func allowDirect() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if muted { return false }
        let now = clock.now()
        let recent = directTimestamps.filter { now - $0 < 60 }
        return recent.count < maxDirectAddressesPerMinute
    }

    /// Record a direct-address reply. Counts toward the direct ceiling but deliberately does NOT
    /// start the ambient cooldown, so replying to the user doesn't mute the next coaching nudge.
    public func noteDirectAddress() {
        lock.lock(); defer { lock.unlock() }
        let now = clock.now()
        directTimestamps.append(now)
        directTimestamps = directTimestamps.filter { now - $0 < 60 }
    }
}
