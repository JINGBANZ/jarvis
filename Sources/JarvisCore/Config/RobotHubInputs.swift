import Foundation

/// Everything the Settings hub shows, read by the app in one pass.
public struct RobotHubInputs: Sendable, Equatable {
    public var route: BrainRoute
    public var effort: ReasoningEffort
    public var transcription: TranscriptionConfiguration
    public var screenScope: ScreenCaptureScope
    public var displayIndex: Int
    public var browserTextEnabled: Bool
    public var captionEnabled: Bool
    public var boxEnabled: Bool
    /// Keys, grants, and sign-ins. Nil until the app has read them, so the hub shows no status.
    public var readiness: RobotReadiness?
    /// The brain the running session is using; nil when stopped.
    public var activeTarget: BrainTarget?

    public init(
        route: BrainRoute,
        effort: ReasoningEffort,
        transcription: TranscriptionConfiguration,
        screenScope: ScreenCaptureScope,
        displayIndex: Int,
        browserTextEnabled: Bool,
        captionEnabled: Bool,
        boxEnabled: Bool,
        readiness: RobotReadiness? = nil,
        activeTarget: BrainTarget? = nil
    ) {
        self.route = route
        self.effort = effort
        self.transcription = transcription
        self.screenScope = screenScope
        self.displayIndex = displayIndex
        self.browserTextEnabled = browserTextEnabled
        self.captionEnabled = captionEnabled
        self.boxEnabled = boxEnabled
        self.readiness = readiness
        self.activeTarget = activeTarget
    }
}
