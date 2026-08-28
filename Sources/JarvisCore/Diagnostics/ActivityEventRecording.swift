import Foundation

/// Human-facing, best-effort session-evidence port.
///
/// A producer states one occurrence from the closed `ActivityEvent` set and the moment it happened;
/// it never authors free-form copy and never learns whether the record survived. Implementations
/// must return immediately, must not throw, and must never invoke coaching callbacks.
///
/// `FileSessionAudit` is the one implementation: it wraps the occurrence into a single `SessionEvent`
/// on the shared bounded transport. The port exists so the kernel names neither that handle nor the
/// `ActivityLog` projection the worker ultimately renders into.
public protocol ActivityEventRecording: Sendable {
    func record(_ event: ActivityEvent, at date: Date)
}

public extension ActivityEventRecording {
    /// Most occurrences happen when they are recorded. Speech is the exception: a finalized
    /// utterance carries its own speech-time so Activity and the model share one chronology.
    func record(_ event: ActivityEvent) {
        record(event, at: Date())
    }
}
