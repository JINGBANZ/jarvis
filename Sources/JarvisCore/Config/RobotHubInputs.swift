import Foundation

public struct RobotHubInputs: Sendable, Equatable {
    public var route: BrainRoute
    public var effort: ReasoningEffort
    public var transcription: TranscriptionConfiguration
    public var screenScope: ScreenCaptureScope
    public var displayIndex: Int
    public var browserTextEnabled: Bool
    public var boxFontSize: Double
    /// `nil` until the app has read it, so the hub shows no status.
    public var readiness: RobotReadiness?
    /// `nil` when stopped.
    public var activeTarget: BrainTarget?

    public init(
        route: BrainRoute,
        effort: ReasoningEffort,
        transcription: TranscriptionConfiguration,
        screenScope: ScreenCaptureScope,
        displayIndex: Int,
        browserTextEnabled: Bool,
        boxFontSize: Double,
        readiness: RobotReadiness? = nil,
        activeTarget: BrainTarget? = nil
    ) {
        self.route = route
        self.effort = effort
        self.transcription = transcription
        self.screenScope = screenScope
        self.displayIndex = displayIndex
        self.browserTextEnabled = browserTextEnabled
        self.boxFontSize = boxFontSize
        self.readiness = readiness
        self.activeTarget = activeTarget
    }
}
