import Foundation

public struct ScreenCaptureSelection: Sendable, Equatable {
    public let scope: ScreenCaptureScope
    /// The `screencapture -D` display, or nil for a plain capture of the main display.
    public let explicitDisplay: Int?
    /// The user's opt-in only. The OS grant is still checked at capture time.
    public let browserTextEnabled: Bool

    public init(scope: ScreenCaptureScope, explicitDisplay: Int?, browserTextEnabled: Bool) {
        self.scope = scope
        self.explicitDisplay = explicitDisplay
        self.browserTextEnabled = browserTextEnabled
    }
}

// Design: wiki/lean-coaching-core.md
/// Frozen at Start or a revision boundary, because a coaching turn never reads storage.
public struct SessionPlan: Sendable, Equatable {
    public let revision: UInt
    public let screen: ScreenCaptureSelection

    // Detail capability lives only on `CoachCapabilities`. A second copy here let the described and
    // sent tool sets diverge.

    public init(revision: UInt, screen: ScreenCaptureSelection) {
        self.revision = revision
        self.screen = screen
    }

    public static let `default` = SessionPlan(
        revision: 0,
        screen: ScreenCaptureSelection(
            scope: Defaults.Screen.scope,
            explicitDisplay: nil,
            browserTextEnabled: Defaults.Screen.browserTextEnabled))
}

public extension ScreenCapturePreferences {
    var selection: ScreenCaptureSelection {
        ScreenCaptureSelection(
            scope: scope,
            explicitDisplay: explicitDisplay,
            browserTextEnabled: browserTextEnabled)
    }
}
