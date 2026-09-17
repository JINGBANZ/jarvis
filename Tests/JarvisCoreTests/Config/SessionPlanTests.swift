import Foundation
import Testing
@testable import JarvisCore

@Suite struct SessionPlanTests {
    /// @unchecked: lock guards storage.
    private final class RecordingScreen: ScreenCapturing, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ScreenCaptureSelection] = []

        func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? {
            lock.withLock { storage.append(selection) }
            return ScreenSnapshot(imageBase64: "c2hvdA==")
        }

        func cancelCapture() {}

        var selections: [ScreenCaptureSelection] { lock.withLock { storage } }
    }

    /// @unchecked: lock guards callCount; beforeReply is set before the driver runs.
    private final class ScriptedBrainWithHook: BrainClient, @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        private let script: [BrainResponse]
        /// Receives the 1-based call number.
        var beforeReply: (@Sendable (Int) -> Void)?

        init(script: [BrainResponse]) { self.script = script }

        func respond(
            messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice
        ) async throws -> BrainResponse {
            let call = lock.withLock { () -> Int in
                callCount += 1
                return callCount
            }
            beforeReply?(call)
            return script[min(call - 1, script.count - 1)]
        }
    }

    private static func captureScreenReply(_ callID: String) -> BrainResponse {
        BrainResponse(
            toolCalls: [.captureScreen(callId: callID)],
            rawToolCalls: [
                RawToolCall(id: callID, name: "capture_screen", argumentsJSON: "{}"),
            ])
    }

    private static func speakReply(_ callID: String, _ line: String) -> BrainResponse {
        BrainResponse(
            toolCalls: [.speak(callId: callID, lines: [line])],
            rawToolCalls: [
                RawToolCall(
                    id: callID, name: "speak",
                    argumentsJSON: "{\"lines\":[\"\(line)\"]}"),
            ])
    }

    private func makeDriver(
        screen: ScreenCapturing,
        brain: BrainClient,
        plan: SessionPlan
    ) -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let target = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
        let driver = CoachDriver(
            config: .default,
            transcript: transcript,
            route: ConfiguredBrainRoute(
                targets: [ConfiguredBrainTarget(target: target, brain: brain)]),
            screen: screen,
            overlay: FakeOverlay(),
            clock: ManualClock(),
            plan: plan,
            automaticAttemptDelay: { _ in })
        return (driver, transcript)
    }

    @Test func aRevisionInstalledMidAttemptDoesNotReachThatAttempt() async throws {
        let screen = RecordingScreen()
        let started = SessionPlan(
            revision: 1,
            screen: ScreenCaptureSelection(
                scope: .activeWindow, explicitDisplay: nil, browserTextEnabled: false))
        let installed = SessionPlan(
            revision: 2,
            screen: ScreenCaptureSelection(
                scope: .entireDisplay, explicitDisplay: 3, browserTextEnabled: true))

        let brain = ScriptedBrainWithHook(script: [
            Self.captureScreenReply("s1"),
            Self.captureScreenReply("s2"),
            Self.speakReply("t", "done"),
        ])
        let (driver, transcript) = makeDriver(screen: screen, brain: brain, plan: started)
        brain.beforeReply = { call in
            if call == 2 { driver.updatePlan(installed) }
        }

        transcript.append(.init(speaker: .me, text: "look at this", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        #expect(screen.selections.count == 2)
        #expect(screen.selections.allSatisfy { $0 == started.screen })
    }

    @Test func theNextAttemptRunsAgainstTheInstalledRevision() async throws {
        let screen = RecordingScreen()
        let started = SessionPlan(
            revision: 1,
            screen: ScreenCaptureSelection(
                scope: .activeWindow, explicitDisplay: nil, browserTextEnabled: false))
        let installed = SessionPlan(
            revision: 2,
            screen: ScreenCaptureSelection(
                scope: .entireDisplay, explicitDisplay: 3, browserTextEnabled: true))

        let brain = ScriptedBrainWithHook(script: [
            Self.captureScreenReply("s1"),
            Self.speakReply("t1", "first"),
            Self.captureScreenReply("s2"),
            Self.speakReply("t2", "second"),
        ])
        let (driver, transcript) = makeDriver(screen: screen, brain: brain, plan: started)

        transcript.append(.init(speaker: .me, text: "first turn", at: 1))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)
        driver.updatePlan(installed)
        transcript.append(.init(speaker: .me, text: "second turn", at: 2))
        #expect(await driver.handleTrigger(.turnEnd) == .spoke)

        #expect(screen.selections == [started.screen, installed.screen])
    }

    @Test func theSelectionIsResolvedFromPreferencesAtTheBoundary() throws {
        let suite = "SessionPlanTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ScreenCapturePreferences(defaults: defaults)

        #expect(preferences.selection
            == ScreenCaptureSelection(
                scope: Defaults.Screen.scope, explicitDisplay: nil, browserTextEnabled: false))

        preferences.scope = .entireDisplay
        preferences.displayIndex = 4
        preferences.browserTextEnabled = true
        #expect(preferences.selection
            == ScreenCaptureSelection(
                scope: .entireDisplay, explicitDisplay: 4, browserTextEnabled: true))

        // The main display needs no explicit -D, so an index of 1 stays nil.
        preferences.displayIndex = 1
        #expect(preferences.selection
            == ScreenCaptureSelection(
                scope: .entireDisplay, explicitDisplay: nil, browserTextEnabled: true))

        preferences.scope = .activeWindow
        preferences.displayIndex = 4
        #expect(preferences.selection
            == ScreenCaptureSelection(
                scope: .activeWindow, explicitDisplay: nil, browserTextEnabled: true))
    }
}
