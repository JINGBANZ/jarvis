import Foundation
import Testing
@testable import JarvisCore

/// The control-plane half of the Lean Coaching Path Rule: preferences are read at a revision
/// boundary, and a coaching turn runs against a frozen snapshot rather than storage.
@Suite struct SessionPlanTests {
    /// Records the selection every capture was handed, so a test can see whether a mid-attempt
    /// change leaked into a turn that had already started.
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

    /// Replays a fixed script and lets the test run something between two calls — the only way to
    /// change the plan while an attempt is genuinely in flight.
    private final class ScriptedBrainWithHook: BrainClient, @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        private let script: [BrainResponse]
        /// Called with the 1-based number of the call that just started.
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

    /// A revision installed while an attempt is running does not reach that attempt — not even its
    /// `capture_screen` continuation, which is the one place a second capture happens in one turn.
    @Test func aRevisionInstalledMidAttemptDoesNotReachThatAttempt() async throws {
        let screen = RecordingScreen()
        let started = SessionPlan(
            revision: 1,
            screen: ScreenCaptureSelection(scope: .activeWindow, explicitDisplay: nil))
        let installed = SessionPlan(
            revision: 2,
            screen: ScreenCaptureSelection(scope: .entireDisplay, explicitDisplay: 3))

        // The brain asks for the screen twice, and the plan changes between the two requests.
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

    /// The very next attempt runs against the installed revision. Forward-only: the boundary is
    /// between attempts, not inside one.
    @Test func theNextAttemptRunsAgainstTheInstalledRevision() async throws {
        let screen = RecordingScreen()
        let started = SessionPlan(
            revision: 1,
            screen: ScreenCaptureSelection(scope: .activeWindow, explicitDisplay: nil))
        let installed = SessionPlan(
            revision: 2,
            screen: ScreenCaptureSelection(scope: .entireDisplay, explicitDisplay: 3))

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

    /// The persisted store is read exactly once per revision, at the boundary — never by a capture.
    @Test func theSelectionIsResolvedFromPreferencesAtTheBoundary() throws {
        let suite = "SessionPlanTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ScreenCapturePreferences(defaults: defaults)

        #expect(preferences.selection
            == ScreenCaptureSelection(scope: Defaults.Screen.scope, explicitDisplay: nil))

        preferences.scope = .entireDisplay
        preferences.displayIndex = 4
        #expect(preferences.selection
            == ScreenCaptureSelection(scope: .entireDisplay, explicitDisplay: 4))

        // The main display needs no explicit -D, so an index of 1 stays nil.
        preferences.displayIndex = 1
        #expect(preferences.selection
            == ScreenCaptureSelection(scope: .entireDisplay, explicitDisplay: nil))

        // A display index left over from an old entire-display selection must not steer
        // active-window captures.
        preferences.scope = .activeWindow
        preferences.displayIndex = 4
        #expect(preferences.selection
            == ScreenCaptureSelection(scope: .activeWindow, explicitDisplay: nil))
    }
}
