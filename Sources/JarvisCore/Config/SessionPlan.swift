import Foundation

/// What `capture_screen` shoots, frozen.
///
/// The persisted preference behind it (`ScreenCapturePreferences`) is read once at a revision
/// boundary; this value is what an attempt actually runs against, so a capture cannot depend on
/// disk latency or on whichever value happened to be current partway through a turn.
public struct ScreenCaptureSelection: Sendable, Equatable {
    public let scope: ScreenCaptureScope
    /// The display a capture must explicitly target (`screencapture -D`), or nil when a plain
    /// capture — which shoots the main display — is right.
    public let explicitDisplay: Int?

    public init(scope: ScreenCaptureScope, explicitDisplay: Int?) {
        self.scope = scope
        self.explicitDisplay = explicitDisplay
    }
}

/// The immutable control-plane snapshot one coaching attempt runs against.
///
/// This is the control-plane half of the Lean Coaching Path Rule (wiki/lean-coaching-core.md).
/// Preferences, secrets, and provider discovery are read at Start or at an explicit
/// between-attempt revision boundary and frozen here; a coaching turn never reads storage. Reading
/// a preference mid-attempt would let a coaching outcome depend on disk latency and on whichever
/// value happened to be current partway through the turn, which is exactly the class of dependency
/// the rule exists to remove.
///
/// A revision is installed only at Start or at a declared boundary, and an attempt keeps the
/// revision it snapshotted for its whole tool loop — including every `capture_screen` continuation.
/// The route half of the control plane is frozen the same way, through `ConfiguredBrainRoute`.
public struct SessionPlan: Sendable, Equatable {
    /// Monotonic identity of this revision. It exists so a reader can tell two plans apart in a
    /// log without comparing every field; nothing branches on its value.
    public let revision: UInt
    public let screen: ScreenCaptureSelection

    public init(revision: UInt, screen: ScreenCaptureSelection) {
        self.revision = revision
        self.screen = screen
    }

    /// The plan a session with no configured control plane runs against: active-window capture on
    /// the main display, which is what the persisted defaults produce.
    public static let `default` = SessionPlan(
        revision: 0,
        screen: ScreenCaptureSelection(
            scope: Defaults.Screen.scope, explicitDisplay: nil))
}

public extension ScreenCapturePreferences {
    /// Read the persisted screen selection once, at a revision boundary. Every later capture in the
    /// attempt reads the returned value, never this store.
    var selection: ScreenCaptureSelection {
        ScreenCaptureSelection(scope: scope, explicitDisplay: explicitDisplay)
    }
}
